@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Observation

@MainActor @Observable
final class Dictation {
    enum State: Equatable {
        case idle
        case preparing(Double)
        case recording
        case finishing
    }

    private(set) var state = State.idle
    private(set) var confirmed = ""
    private(set) var volatile = ""
    var errorMessage: String?

    @ObservationIgnored private var models: AsrModels?
    @ObservationIgnored private var manager: SlidingWindowAsrManager?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var feed: AsyncStream<AVAudioPCMBuffer>.Continuation?
    @ObservationIgnored private let engine = AVAudioEngine()

    var isRecording: Bool { state == .recording }

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        confirmed = ""
        volatile = ""
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            errorMessage = "Microphone access is off. Allow Brain Dump in System Settings › Privacy & Security › Microphone, or just type."
            return
        }
        state = .preparing(0)
        do {
            let mgr = try await beginSession()
            attachFeed(to: mgr)
            try startEngine()
            state = .recording
        } catch {
            await teardown()
            errorMessage = "Could not start dictation: \(error.localizedDescription)"
            state = .idle
        }
    }

    func stop() async -> String {
        guard state == .recording else { return "" }
        state = .finishing
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        feed?.finish()
        feed = nil
        await pumpTask?.value
        pumpTask = nil
        let text = await endSession()
        confirmed = ""
        volatile = ""
        state = .idle
        return text
    }

    func releaseModels() { models = nil }

    /// Runs a sound file through the same streaming path as the microphone.
    func transcribe(file url: URL) async throws -> String {
        state = .preparing(0)
        defer { state = .idle }
        let mgr = try await beginSession()
        let audio = try AVAudioFile(forReading: url)
        let format = audio.processingFormat
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { break }
            try audio.read(into: buffer)
            if buffer.frameLength == 0 { break }
            await mgr.streamAudio(buffer)
        }
        return await endSession()
    }

    private func beginSession() async throws -> SlidingWindowAsrManager {
        let models = try await loadedModels()
        let mgr = SlidingWindowAsrManager(config: .streaming)
        try await mgr.loadModels(models)
        let updates = await mgr.transcriptionUpdates
        updatesTask = Task { [weak self] in
            for await update in updates {
                self?.confirmed = update.confirmedTranscript
                self?.volatile = update.volatileTranscript
            }
        }
        try await mgr.startStreaming(source: .microphone)
        manager = mgr
        return mgr
    }

    private func endSession() async -> String {
        guard let mgr = manager else { return "" }
        let final = try? await mgr.finish()
        let text = final ?? [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
        await teardown()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func teardown() async {
        updatesTask?.cancel()
        updatesTask = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        feed?.finish()
        feed = nil
        pumpTask = nil
        if let mgr = manager { await mgr.cleanup() }
        manager = nil
    }

    private func loadedModels() async throws -> AsrModels {
        if let models { return models }
        let loaded = try await AsrModels.downloadAndLoad(version: .bark3Clean) { [weak self] progress in
            Task { @MainActor in
                guard let self, case .preparing = self.state else { return }
                self.state = .preparing(progress.fractionCompleted)
            }
        }
        models = loaded
        return loaded
    }

    private func attachFeed(to mgr: SlidingWindowAsrManager) {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        feed = continuation
        pumpTask = Task { for await buffer in stream { await mgr.streamAudio(buffer) } }
    }

    private func startEngine() throws {
        guard let feed else { return }
        Self.installTap(on: engine, feed: feed)
        engine.prepare()
        try engine.start()
    }

    nonisolated private static func installTap(on engine: AVAudioEngine, feed: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
            feed.yield(buffer)
        }
    }
}
