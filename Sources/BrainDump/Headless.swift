import AVFoundation
import BrainDumpCore
import BrainDumpLLM
import Foundation

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
        if let modelID {
            guard let m = ModelCatalog.model(id: modelID) else { throw AppError("Unknown model id \(modelID)") }
            model = m
        } else {
            model = Prefs.localModel
        }
        let provider = try await Pipeline.provider(cloud: modelID == nil && Prefs.useCloud, local: model) { err($0) }
        let result: ExtractionResult
        do {
            result = try await Extractor(provider: provider.llm).extract(text) { done, total in err("Reading \(done) of \(total)") }
        } catch {
            await provider.local?.unload()
            throw error
        }
        await provider.local?.unload()

        let connectors = Pipeline.connectors(store: store)
        let context = ActionContext(journal: journal, now: Date())
        print("\(result.items.count) item(s), \(result.rejected.count) rejected")
        for item in result.items {
            let due = item.due.map { " due \($0.formatted())\(item.dueHasTime ? "" : " (all day)")" } ?? ""
            print("- [\(item.kind.rawValue)] \(item.title)\(due)\(item.lowConfidence ? " (unsure)" : "")")
            print("    quote: \(item.quote)")
            guard let c = Pipeline.connector(for: item.kind, in: connectors) else { continue }
            if c.id == "reminders" {
                print("    would create in \(c.destination(for: item))")
            } else {
                let r = try await c.execute(item, context: context)
                print("    \(r.summary)  \(r.openURL?.path ?? "")")
            }
        }
        let summaries = result.items.isEmpty ? [] : ["(headless run)"]
        if !summaries.isEmpty { try store.appendActions(summaries, to: journal) }
    }
}
