import Foundation

// MARK: - Language model

public struct ChatTurn: Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

public protocol LLMProvider: Sendable {
    /// Returns the assistant's reply. `grammar` is GBNF; providers that cannot constrain decoding
    /// must still return text that the caller validates.
    func complete(turns: [ChatTurn], grammar: String?, maxTokens: Int) async throws -> String
}

// MARK: - Dates

public struct ResolvedDate: Sendable, Equatable {
    public let date: Date
    /// False means the phrase named a day only.
    public let hasTime: Bool

    public init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }
}

// MARK: - Notes

public struct NoteRef: Sendable, Codable, Equatable {
    public let url: URL
    /// Path relative to the notes root without extension, e.g. "Ideas/voice-journal".
    public let wikiLink: String

    public init(url: URL, wikiLink: String) {
        self.url = url
        self.wikiLink = wikiLink
    }
}

// MARK: - Connectors

public struct ActionContext: Sendable {
    public let journal: NoteRef
    public let now: Date
    /// The item's category: its name, notes folder and so on.
    public let category: ItemCategory

    public init(journal: NoteRef, now: Date, category: ItemCategory) {
        self.journal = journal
        self.now = now
        self.category = category
    }
}

public struct ActionResult: Sendable, Identifiable {
    public var id: UUID { itemID }
    public let itemID: UUID
    public let connectorID: String
    /// One line for the summary screen, e.g. "Reminder: Call the dentist (tomorrow 9:00)".
    public let summary: String
    /// Whatever `undo` needs to reverse the action.
    public let undoToken: String?
    public let openURL: URL?

    public init(itemID: UUID, connectorID: String, summary: String, undoToken: String?, openURL: URL?) {
        self.itemID = itemID
        self.connectorID = connectorID
        self.summary = summary
        self.undoToken = undoToken
        self.openURL = openURL
    }
}

/// Each category names one connector through `ItemCategory.destination`, whose raw value is the connector's `id`.
public protocol Connector: Sendable {
    var id: String { get }
    var name: String { get }
    /// Where the item will go, shown on the review card, e.g. "Reminders › Brain Dump".
    func destination(for item: ExtractedItem, category: ItemCategory) -> String
    func execute(_ item: ExtractedItem, context: ActionContext) async throws -> ActionResult
    func undo(_ result: ActionResult) async throws
}
