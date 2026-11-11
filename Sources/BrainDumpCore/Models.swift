import Foundation

public enum ItemKind: String, Codable, CaseIterable, Sendable {
    /// Work to do today or soon.
    case task
    /// Personal thing not to forget.
    case reminder
    /// Creative or project idea worth keeping.
    case idea
    /// Reflection or lingering concern worth keeping, not actionable.
    case thought

    public var label: String {
        switch self {
        case .task: return "To-do"
        case .reminder: return "To-do"
        case .idea: return "Idea"
        case .thought: return "Thought"
        }
    }

    public var pluralLabel: String { label + "s" }

    public var isActionable: Bool { self == .task || self == .reminder }
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
