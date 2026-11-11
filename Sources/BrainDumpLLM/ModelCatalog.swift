import BrainDumpCore
import Foundation

public struct LocalModel: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let url: URL
    public let sizeMB: Int
    public let note: String

    public init(id: String, name: String, url: URL, sizeMB: Int, note: String) {
        self.id = id
        self.name = name
        self.url = url
        self.sizeMB = sizeMB
        self.note = note
    }
}

public enum ModelCatalogError: LocalizedError {
    case http(Int)
    case incomplete

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "Model download failed (HTTP \(code))."
        case .incomplete: return "Model download did not complete."
        }
    }
}

public enum ModelCatalog {
    private static func hf(_ repo: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    /// Smallest first.
    public static var all: [LocalModel] { models }

    private static let models: [LocalModel] = [
        LocalModel(
            id: "lfm2.5-350m", name: "LFM2.5 350M",
            url: hf("LiquidAI/LFM2.5-350M-GGUF", "LFM2.5-350M-Q4_K_M.gguf"), sizeMB: 229,
            note: "229 MB, ~100 tok/s. Dev recall 80%, precision 56%, weak kind accuracy (66%)."),
        LocalModel(
            id: "qwen3.5-0.8b", name: "Qwen3.5 0.8B",
            url: hf("unsloth/Qwen3.5-0.8B-GGUF", "Qwen3.5-0.8B-Q4_K_M.gguf"), sizeMB: 532,
            note: "532 MB, ~27 tok/s. Dev (first prompt only) recall 75%, precision 47%. Slowest per size."),
        LocalModel(
            id: "lfm2.5-1.2b", name: "LFM2.5 1.2B Instruct",
            url: hf("LiquidAI/LFM2.5-1.2B-Instruct-GGUF", "LFM2.5-1.2B-Instruct-Q4_K_M.gguf"), sizeMB: 731,
            note: "731 MB, ~60 tok/s. Dev recall 90%, precision 55%; holdout 95% / 62%."),
        LocalModel(
            id: "lfm3-1.7b", name: "LFM3 1.7B",
            url: hf("LiquidAI/LFM3-1.7B-GGUF", "LFM3-1.7B-Q4_K_M.gguf"), sizeMB: 1100,
            note: "Runs on any Apple Silicon Mac. Catches slightly more than Apple's model, with more suggestions to dismiss."),
        LocalModel(
            id: "qwen3.5-2b", name: "Qwen3.5 2B",
            url: hf("unsloth/Qwen3.5-2B-GGUF", "Qwen3.5-2B-Q4_K_M.gguf"), sizeMB: 1280,
            note: "1.3 GB. Not evaluated."),
    ]

    public static var defaultModel: LocalModel { model(id: "lfm3-1.7b")! }

    public static func model(id: String) -> LocalModel? { all.first { $0.id == id } }

    /// Downloaded model files other than `defaultModel`, which the app no longer offers (the eval still can).
    public static var unusedDownloads: [URL] {
        let keep = localURL(for: defaultModel).lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "gguf" && $0.lastPathComponent != keep }
    }

    /// ~/Library/Application Support/BrainDump/Models
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("BrainDump/Models", isDirectory: true)
    }

    public static func localURL(for model: LocalModel) -> URL {
        directory.appendingPathComponent(model.url.lastPathComponent)
    }

    public static func isDownloaded(_ model: LocalModel) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: model).path)
    }

    /// Downloads to `localURL(for:)`, reporting 0...1. Resumable is not required; partial files must not be left behind.
    public static func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = localURL(for: model)
        let partial = directory.appendingPathComponent("." + model.url.lastPathComponent + ".part")
        try? fm.removeItem(at: partial)

        let delegate = DownloadDelegate(partial: partial, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    delegate.continuation = cont
                    session.downloadTask(with: model.url).resume()
                }
            } onCancel: {
                session.invalidateAndCancel()
            }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: partial, to: destination)
            progress(1)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let partial: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private let lock = NSLock()

    init(partial: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.partial = partial
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns, so it must be moved now.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = ModelCatalogError.http(http.statusCode)
            return
        }
        do { try FileManager.default.moveItem(at: location, to: partial) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        if let error = error ?? moveError {
            cont?.resume(throwing: error)
        } else if FileManager.default.fileExists(atPath: partial.path) {
            cont?.resume()
        } else {
            cont?.resume(throwing: ModelCatalogError.incomplete)
        }
    }
}
