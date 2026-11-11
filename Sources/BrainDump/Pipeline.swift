import BrainDumpCore
import BrainDumpLLM
import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Provider {
    let llm: any LLMProvider
    let local: LocalLLM?
}

enum Pipeline {
    static func provider(cloud: Bool, local model: LocalModel, status: @escaping @Sendable (String) -> Void) async throws -> Provider {
        if cloud {
            guard let key = Keychain.get(), !key.isEmpty else {
                throw AppError("No Anthropic API key. Add one in Settings, or switch to a local model.")
            }
            return Provider(llm: CloudLLM(apiKey: key, model: Prefs.cloudModel), local: nil)
        }
        if !ModelCatalog.isDownloaded(model) {
            status("Downloading model 0%")
            try await ModelCatalog.download(model) { fraction in
                status("Downloading model \(Int(fraction * 100))%")
            }
        }
        status("Loading model…")
        let llm = LocalLLM(modelPath: ModelCatalog.localURL(for: model))
        return Provider(llm: llm, local: llm)
    }

    static func connectors(store: NotesStore) -> [any Connector] {
        [RemindersConnector(listName: Prefs.remindersList), NotesConnector(store: store)]
    }

    /// Connectors the user has not switched off in Settings.
    static func enabledConnectors(store: NotesStore) -> [any Connector] {
        connectors(store: store).filter { $0.id == "reminders" ? Prefs.remindersEnabled : Prefs.notesEnabled }
    }

    static func connector(for kind: ItemKind, in connectors: [any Connector]) -> (any Connector)? {
        connectors.first { $0.handles(kind) }
    }
}
