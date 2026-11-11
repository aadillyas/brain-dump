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
    var options = ExtractorOptions()
    /// Shown while reading, e.g. "Apple's model".
    var name: String
}

enum Pipeline {
    /// `apple` asks for Apple's on-device model; when it is unavailable the local GGUF `model` is used instead,
    /// and when it fails on a chunk that chunk falls back to `model` if it is already downloaded.
    static func provider(cloud: Bool, apple: Bool = false, local model: LocalModel,
                         status: @escaping @Sendable (String) -> Void) async throws -> Provider {
        if cloud {
            guard let key = Keychain.get(), !key.isEmpty else {
                throw AppError("No Anthropic API key. Add one in Settings, or switch to a local model.")
            }
            return Provider(llm: CloudLLM(apiKey: key, model: Prefs.cloudModel), local: nil, name: "Claude")
        }
        if apple {
            if #available(macOS 26.0, *), AppleLLM.isAvailable {
                let fallback = ModelCatalog.isDownloaded(model) ? LocalLLM(modelPath: ModelCatalog.localURL(for: model)) : nil
                return Provider(llm: FallbackLLM(primary: AppleLLM(), fallback: fallback), local: fallback,
                                options: .appleOnDevice, name: "Apple's model")
            }
            status("Apple's model is unavailable (\(appleUnavailableReason)), using \(model.name)")
        }
        if !ModelCatalog.isDownloaded(model) {
            status("Downloading model 0%")
            try await ModelCatalog.download(model) { fraction in
                status("Downloading model \(Int(fraction * 100))%")
            }
        }
        status("Loading model…")
        let llm = LocalLLM(modelPath: ModelCatalog.localURL(for: model))
        return Provider(llm: llm, local: llm, name: model.name)
    }

    /// Why Apple's on-device model cannot be used, for status and Settings text.
    static var appleUnavailableReason: String {
        if #available(macOS 26.0, *) { return AppleLLM.availability ?? "available" }
        return "needs macOS 26 or later"
    }

    static var appleAvailable: Bool {
        if #available(macOS 26.0, *) { return AppleLLM.isAvailable }
        return false
    }

    static func connectors(store: NotesStore) -> [any Connector] {
        [RemindersConnector(listName: Prefs.remindersList), CalendarConnector(), NotesConnector(store: store)]
    }

    /// Connectors the user has not switched off in Settings.
    static func enabledConnectors(store: NotesStore) -> [any Connector] {
        connectors(store: store).filter {
            switch $0.id {
            case Destination.reminders.rawValue: return Prefs.remindersEnabled
            case Destination.calendar.rawValue: return Prefs.calendarEnabled
            default: return Prefs.notesEnabled
            }
        }
    }

    /// The connector a category's items go to, with that category; nil when it is unknown or switched off.
    static func route(_ kind: ItemKind, in connectors: [any Connector]) -> (connector: any Connector, category: ItemCategory)? {
        guard let category = ItemCategory.defaults.category(for: kind),
              let connector = connectors.first(where: { $0.id == category.destination.rawValue }) else { return nil }
        return (connector, category)
    }

    /// Extraction settings for `provider`, with the user's enabled categories.
    static func extractorOptions(_ provider: Provider) -> ExtractorOptions {
        var options = provider.options
        options.categories = ItemCategory.defaults.enabled
        return options
    }
}
