import AVFoundation
import AppKit
import BrainDumpCore
import BrainDumpLLM
import Foundation
import SwiftUI

enum Headless {
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Returns true when a headless flag was found; the process exits when the work is done.
    static func runIfRequested(_ args: [String]) -> Bool {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let path = value("--transcribe-file") {
            Task { @MainActor in
                do {
                    print(try await Dictation().transcribe(file: URL(fileURLWithPath: path)))
                    exit(0)
                } catch {
                    err("error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return true
        }
        if let name = value("--snapshot-section") {
            MainActor.assumeIsolated { Simulation.snapshotSection(name) }
            NSApplication.shared.run()
            return true
        }
        if let path = value("--simulate-dump") {
            MainActor.assumeIsolated { Simulation.start(path: path) }
            NSApplication.shared.run()
            return true
        }
        if let dir = value("--render-ui") {
            Task { @MainActor in
                renderUI(to: URL(fileURLWithPath: dir))
                exit(0)
            }
            return true
        }
        if let path = value("--process-text") {
            Task {
                do {
                    try await processText(path: path, notesRoot: value("--notes-root"), modelID: value("--model"))
                    exit(0)
                } catch {
                    err("error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return true
        }
        return false
    }

    private static func processText(path: String, notesRoot: String?, modelID: String?) async throws {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = notesRoot.map { URL(fileURLWithPath: $0) } ?? Prefs.notesRoot
        let store = NotesStore(root: root)
        try store.prepare()
        let journal = try store.writeJournal(text: text, date: Date())
        print("Journal: \(journal.url.path)")

        let model: LocalModel
        let apple = modelID == Prefs.appleModelID || (modelID == nil && Prefs.useApple)
        if apple {
            model = Prefs.localModel
        } else if let modelID {
            guard let m = ModelCatalog.model(id: modelID) else { throw AppError("Unknown model id \(modelID)") }
            model = m
        } else {
            model = Prefs.localModel
        }
        let provider = try await Pipeline.provider(cloud: modelID == nil && Prefs.useCloud, apple: apple, local: model) { err($0) }
        err("Model: \(provider.name)")
        let result: ExtractionResult
        do {
            var extractor = Extractor(provider: provider.llm)
            extractor.options = Pipeline.extractorOptions(provider)
            result = try await extractor.extract(text) { done, total in err("Reading \(done) of \(total)") }
        } catch {
            await provider.local?.unload()
            throw error
        }
        await provider.local?.unload()

        let connectors = Pipeline.connectors(store: store)
        print("\(result.items.count) item(s), \(result.rejected.count) rejected")
        for item in result.items {
            let due = item.due.map { " due \($0.formatted())\(item.dueHasTime ? "" : " (all day)")" } ?? ""
            print("- [\(item.kind.rawValue)] \(item.title)\(due)\(item.lowConfidence ? " (unsure)" : "")")
            print("    quote: \(item.quote)")
            guard let (c, category) = Pipeline.route(item.kind, in: connectors) else { continue }
            let context = ActionContext(journal: journal, now: Date(), category: category)
            if category.isActionable {
                print("    would create in \(c.destination(for: item, category: category))")
            } else {
                let r = try await c.execute(item, context: context)
                print("    \(r.summary)  \(r.openURL?.path ?? "")")
            }
        }
        let summaries = result.items.isEmpty ? [] : ["(headless run)"]
        if !summaries.isEmpty { try store.appendActions(summaries, to: journal) }
    }

    /// Draws the main windows off-screen to PNGs: a crash check for view code, and screenshots for review.
    @MainActor private static func renderUI(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel()
        func save(_ name: String, _ view: some View, size: CGSize) {
            let renderer = ImageRenderer(content: view.environment(model).frame(width: size.width, height: size.height))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                err("could not render \(name)")
                return
            }
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
            print("rendered \(name)")
        }
        save("settings", SettingsView(), size: CGSize(width: 560, height: 720))
        // Forms do not draw off-screen; render the settings sections on their own as well.
        save("settings-model", VStack(alignment: .leading) { ModelPicker(); UnusedModelsRow() }.padding(), size: CGSize(width: 560, height: 220))
        for step in 0..<4 { save("intro-\(step + 1)", IntroView(step: step), size: CGSize(width: 540, height: 400)) }
        save("processing", ProcessingView(status: "Reading your dump 1 of 2 · Apple's model"), size: CGSize(width: 700, height: 400))
        save("graph", GraphView(), size: CGSize(width: 900, height: 650))
        // List and ScrollView content does not draw off-screen; the real window is covered by --simulate-dump.
        save("notes", NotesView(), size: CGSize(width: 1000, height: 680))
        save("journal", JournalView(), size: CGSize(width: 1000, height: 680))
        save("root", RootView(), size: CGSize(width: 1180, height: 760))
        let cal = Calendar.current
        let from = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let digest = ReviewDigest.build(root: Prefs.notesRoot, from: from, to: cal.date(byAdding: .day, value: 7, to: from) ?? from)
        save("review", ReviewContent(digest: digest, thisWeek: true).padding(40).frame(maxHeight: .infinity, alignment: .top).background(Theme.paper), size: CGSize(width: 800, height: 900))
        save("review-page", WeeklyReviewView(), size: CGSize(width: 800, height: 900))
    }
}

/// Drives the real AppModel and window through a dump inside a running app event loop, printing the model's
/// state and snapshotting the window one second after every change. Run with `-notesPath <copy of notes>`.
@MainActor enum Simulation {
    static var model: AppModel!
    static var host: NSHostingView<AnyView>!
    static var window: NSWindow!
    static var start = Date()
    static var last = ""
    static var changedAt: Date?
    static var shot = 0
    static let shots = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bd-shots")

    static func start(path: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        model = AppModel()
        model.text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        host = NSHostingView(rootView: AnyView(RootView().environment(model)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        try? FileManager.default.removeItem(at: shots)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        model.done()
        start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
    }

    /// Opens the real window on one section (review, notes, journal, graph) and snapshots it after it loads.
    static func snapshotSection(_ name: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        model = AppModel()
        switch name {
        case "review": model.section = .review
        case "journal": model.section = .journal
        case "graph": model.openGraph()
        default: model.section = .notes
        }
        host = NSHostingView(rootView: AnyView(RootView().environment(model)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                snapshot("section-" + name)
                exit(0)
            }
        }
    }

    static func tick() {
        let cards = model.review.map { e in
            let topic = e.topic.map { " → \($0.title)" } ?? ""
            return "[\(e.item.kind.rawValue)] \(e.item.title) <\(e.status)>\(topic)"
        }
        let line = "\(model.phase) | \(cards.joined(separator: " ; "))"
        let elapsed = Date().timeIntervalSince(start)
        if line != last {
            print(String(format: "%5.1fs  ", elapsed) + line)
            last = line
            changedAt = Date()
        }
        if let changedAt, Date().timeIntervalSince(changedAt) > 1 {
            snapshot(String(String(describing: model.phase).prefix(10).filter(\.isLetter)))
            Self.changedAt = nil
        }
        if elapsed > 30 { exit(0) }
    }

    static func snapshot(_ label: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        shot += 1
        let url = shots.appendingPathComponent(String(format: "%02d-%@.png", shot, label))
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("        snapshot \(url.path)")
    }
}
