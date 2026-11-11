import Foundation

/// A category id, e.g. "todo". Categories themselves are data (`ItemCategory`), so users can rename,
/// redefine, add and disable them; the four built-in ids are spelled out for code that needs them.
public struct ItemKind: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let todo = ItemKind("todo")
    public static let event = ItemKind("event")
    public static let note = ItemKind("note")
}

/// Where items of a category go. The raw value is the connector id.
public enum Destination: String, Codable, CaseIterable, Sendable {
    case reminders, calendar, notes

    public var label: String {
        switch self {
        case .reminders: return "Reminders"
        case .calendar: return "Calendar"
        case .notes: return "Notes"
        }
    }

    /// Reminders and Calendar items get a due date; notes do not.
    public var isActionable: Bool { self != .notes }
}

public struct ItemCategory: Codable, Identifiable, Hashable, Sendable {
    /// Lowercase letters, digits and hyphens; the model writes it, so it must stay grammar-safe.
    public var id: String
    public var name: String
    /// One line the model reads: what belongs here and what does not.
    public var definition: String
    /// Short sample sentences, shown to the model with the definition.
    public var examples: [String]
    public var destination: Destination
    /// Notes folder for `.notes` categories, relative to the notes root.
    public var folder: String
    /// SF Symbol name.
    public var symbol: String
    public var enabled: Bool

    public var kind: ItemKind { ItemKind(id) }
    public var isActionable: Bool { destination.isActionable }

    public init(id: String, name: String, definition: String, examples: [String], destination: Destination,
                folder: String = "", symbol: String, enabled: Bool = true) {
        self.id = Self.slug(id)
        self.name = name
        self.definition = definition
        self.examples = examples
        self.destination = destination
        self.folder = folder
        self.symbol = symbol
        self.enabled = enabled
    }

    public static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.hasSuffix("-") && !out.isEmpty { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "category" : String(out.prefix(24))
    }

    public static let defaults: [ItemCategory] = [
        ItemCategory(
            id: "todo", name: "To-do",
            definition: "something the speaker must do themselves, today or soon: work, errands, things not to forget.",
            examples: ["I need to send the invoice to Marco before noon.", "Pick up the prescription on the way home."],
            destination: .reminders, symbol: "checkmark.circle"),
        ItemCategory(
            id: "event", name: "Event",
            definition: "something happening at a set day or time, usually with other people: a meeting, call, appointment or plan.",
            examples: ["Call with Jeb tomorrow at three.", "Dentist on Thursday at ten."],
            destination: .calendar, symbol: "calendar"),
        ItemCategory(
            id: "note", name: "Note",
            definition: "anything else worth keeping that is not something to do: an idea, a plan, a worry, a feeling or a reflection about the speaker's life, work or people close to them.",
            examples: ["What if onboarding was a little quest map?", "I've been worried about Dad since his fall."],
            destination: .notes, folder: "Notes", symbol: "note.text"),
    ]
}

extension Array where Element == ItemCategory {
    public var enabled: [ItemCategory] { filter(\.enabled) }
    public func category(for kind: ItemKind) -> ItemCategory? { first { $0.id == kind.rawValue } }
    /// Folders scanned for existing notes (related-note search, library, graph).
    public var noteFolders: [String] {
        var out: [String] = []
        for c in self where c.destination == .notes && !c.folder.isEmpty && !out.contains(c.folder) { out.append(c.folder) }
        return out
    }
}

public struct Sentence: Codable, Sendable, Equatable {
    /// Position in the whole dump, starting at 0.
    public let index: Int
    public let text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

public struct ExtractedItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: ItemKind
    /// The only model-written text in an item. Everything else is copied from the dump.
    public var title: String
    public var sentenceIndices: [Int]
    /// The cited sentences, verbatim.
    public var quote: String
    public var due: Date?
    /// False means `due` is a day, not a moment.
    public var dueHasTime: Bool
    public var whenText: String?
    /// True when the title shares few words with the cited sentences.
    public var lowConfidence: Bool
    /// For notes: add this item to an existing note instead of creating one.
    public var addTo: URL? = nil

    public init(
        id: UUID = UUID(), kind: ItemKind, title: String, sentenceIndices: [Int], quote: String,
        due: Date? = nil, dueHasTime: Bool = false, whenText: String? = nil, lowConfidence: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sentenceIndices = sentenceIndices
        self.quote = quote
        self.due = due
        self.dueHasTime = dueHasTime
        self.whenText = whenText
        self.lowConfidence = lowConfidence
    }
}

public struct ExtractionResult: Sendable {
    public var sentences: [Sentence]
    public var items: [ExtractedItem]
    /// Model outputs the validator threw away, for the eval report.
    public var rejected: [String]

    public init(sentences: [Sentence], items: [ExtractedItem], rejected: [String] = []) {
        self.sentences = sentences
        self.items = items
        self.rejected = rejected
    }
}
