import BrainDumpCore
import Foundation

public struct ExtractorOptions: Sendable {
    /// What the model may label lines as. Only enabled categories should be passed.
    public var categories: [ItemCategory] = ItemCategory.defaults
    /// Drop items whose title shares no content word with the cited lines (copied few-shot titles, hallucinations).
    public var rejectUnrelatedTitles = true
    public var maxChunkWords = 110
    public var maxChunkLines = 9
    public var maxTokensPerChunk = 384
    /// Off only while DateResolver is unavailable (evals during development).
    public var resolveDates = true

    public init() {}
}

/// One model answer before validation.
struct RawItem {
    var lines: [Int]
    var kind: String
    var title: String
    var when: String
}

public struct Extractor: Sendable {
    /// The first words of a sentence, without leading filler: a title for text with no model-written one.
    public static func fallbackTitle(_ text: String) -> String { Validator.fallbackTitle(text) }

    public let provider: any LLMProvider
    public let now: Date
    public let calendar: Calendar
    public var options = ExtractorOptions()

    public init(provider: any LLMProvider, now: Date = Date(), calendar: Calendar = .current) {
        self.provider = provider
        self.now = now
        self.calendar = calendar
    }

    /// Segments the dump, asks the model about each chunk, validates and dates every item.
    /// `progress` receives (chunks done, chunks total).
    public func extract(_ text: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ExtractionResult {
        let sentences = Segmenter.sentences(in: text)
        let chunks = Segmenter.chunks(sentences, maxWords: options.maxChunkWords, maxLines: options.maxChunkLines)
        var validator = Validator(sentences: sentences, now: now, calendar: calendar, options: options)
        progress?(0, chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let lines = chunk.map(\.text)
            let output = try await provider.complete(
                turns: LinePrompt.turns(for: lines, categories: options.categories),
                grammar: LinePrompt.grammar(for: lines, categories: options.categories),
                maxTokens: options.maxTokensPerChunk + 8 * lines.count)
            validator.accept(lineOutput: output, chunk: chunk, chunkIndex: index)
            progress?(index + 1, chunks.count)
        }
        return ExtractionResult(sentences: sentences, items: validator.items, rejected: validator.rejected)
    }
}

/// Turns raw model answers into items, checking every claim against the dump.
struct Validator {
    let sentences: [Sentence]
    let now: Date
    let calendar: Calendar
    let options: ExtractorOptions
    var items: [ExtractedItem] = []
    var rejected: [String] = []

    init(sentences: [Sentence], now: Date, calendar: Calendar, options: ExtractorOptions) {
        self.sentences = sentences
        self.now = now
        self.calendar = calendar
        self.options = options
    }

    mutating func accept(lineOutput output: String, chunk: [Sentence], chunkIndex: Int) {
        guard let labels = LinePrompt.parse(output, lineCount: chunk.count) else {
            rejected.append("chunk \(chunkIndex + 1): unreadable output \(output.prefix(80).debugDescription)")
            return
        }
        for label in labels {
            let raw = RawItem(lines: [label.line], kind: label.kind, title: label.title, when: label.when)
            if let item = validate(raw, chunk: chunk, chunkIndex: chunkIndex) { items.append(item) }
        }
    }

    mutating func validate(_ raw: RawItem, chunk: [Sentence], chunkIndex: Int) -> ExtractedItem? {
        let label = "chunk \(chunkIndex + 1) \"\(raw.title.prefix(50))\""
        guard var category = options.categories.category(for: ItemKind(raw.kind.lowercased())) else {
            rejected.append("\(label): unknown kind \(raw.kind)")
            return nil
        }
        var lineNumbers: [Int] = []
        for n in raw.lines where !lineNumbers.contains(n) {
            guard (1...chunk.count).contains(n) else {
                rejected.append("\(label): line \(n) out of range")
                continue
            }
            lineNumbers.append(n)
        }
        guard !lineNumbers.isEmpty else {
            rejected.append("\(label): no valid lines")
            return nil
        }
        let cited = lineNumbers.sorted().map { chunk[$0 - 1] }
        // A labelled line with no title (Apple's model does this for reflections) keeps its label and
        // borrows the start of the line as its title, flagged low-confidence for review.
        var title = Self.cleanTitle(raw.title)
        let untitled = title.isEmpty
        if untitled { title = Self.cleanTitle(Self.fallbackTitle(cited.map(\.text).joined(separator: " "))) }
        guard !title.isEmpty else {
            rejected.append("\(label): empty title")
            return nil
        }
        let quote = cited.map(\.text).joined(separator: " ")
        let overlap = Self.overlap(title: title, source: quote)
        if options.rejectUnrelatedTitles && overlap == 0 {
            rejected.append("\(label): title unrelated to cited lines")
            return nil
        }
        var item = ExtractedItem(
            kind: category.kind, title: title, sentenceIndices: cited.map(\.index), quote: quote,
            lowConfidence: untitled || overlap < 0.34)

        if category.isActionable { date(&item, when: raw.when, label: label) }
        // A calendar event needs a date; without one it is something to do, if a Reminders category exists.
        if category.destination == .calendar, item.due == nil,
           let todo = options.categories.first(where: { $0.destination == .reminders }) {
            category = todo
            item.kind = todo.kind
        }

        if let dup = items.first(where: { Self.isDuplicate($0, item) }) {
            rejected.append("\(label): duplicate of \"\(dup.title)\"")
            return nil
        }
        return item
    }

    private mutating func date(_ item: inout ExtractedItem, when: String, label: String) {
        guard options.resolveDates else { return }
        let resolver = DateResolver(now: now, calendar: calendar)
        let phrase = when.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if !phrase.isEmpty {
            if Self.normalized(item.quote).contains(Self.normalized(phrase)) {
                if let resolved = resolver.resolve(phrase) {
                    item.due = resolved.date
                    item.dueHasTime = resolved.hasTime
                    item.whenText = phrase
                    return
                }
                if let found = resolver.firstDate(in: phrase) {
                    item.due = found.resolved.date
                    item.dueHasTime = found.resolved.hasTime
                    item.whenText = found.phrase
                    return
                }
            } else {
                rejected.append("\(label): when \"\(phrase)\" not in cited lines")
            }
        }
        if let found = resolver.firstDate(in: item.quote) {
            item.due = found.resolved.date
            item.dueHasTime = found.resolved.hasTime
            item.whenText = found.phrase
            return
        }
    }

    // MARK: - Text helpers

    /// The first words of a sentence, without leading filler, for an item the model left untitled.
    static func fallbackTitle(_ text: String) -> String {
        let filler: Set<String> = ["oh", "um", "uh", "and", "so", "well", "okay", "ok", "honestly", "like", "anyway", "also", "i", "guess", "think", "know"]
        var words = text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        while let first = words.first, filler.contains(first.lowercased()) || first.isEmpty { words.removeFirst() }
        return words.prefix(8).joined(separator: " ")
    }

    static func cleanTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") || t.hasSuffix(",") { t.removeLast() }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = t.first else { return "" }
        return first.uppercased() + t.dropFirst()
    }

    /// Lowercased words separated by single spaces, padded so `contains` matches whole words.
    static func normalized(_ text: String) -> String {
        let cleaned = String(text.lowercased().map { $0.isLetter || $0.isNumber || $0 == ":" ? $0 : " " })
        return " " + cleaned.split(separator: " ").joined(separator: " ") + " "
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "about", "into", "onto", "your", "my", "our", "their",
        "his", "her", "its", "a", "an", "to", "of", "on", "in", "at", "by", "up", "out", "off", "or", "be", "is", "are",
        "get", "make", "do", "some", "new", "more",
    ]

    static func contentWords(_ text: String) -> [String] {
        normalized(text).split(separator: " ").map(String.init).filter { $0.count > 2 && !stopwords.contains($0) }
    }

    /// Share of the title's content words that appear in the source, matching on a 4-letter stem.
    static func overlap(title: String, source: String) -> Double {
        let words = contentWords(title)
        guard !words.isEmpty else { return 0 }
        let stems = Set(contentWords(source).map { String($0.prefix(4)) })
        let hits = words.filter { stems.contains(String($0.prefix(4))) }.count
        return Double(hits) / Double(words.count)
    }

    static func isDuplicate(_ a: ExtractedItem, _ b: ExtractedItem) -> Bool {
        if Set(a.sentenceIndices) == Set(b.sentenceIndices) && a.kind == b.kind { return true }
        let wa = Set(contentWords(a.title)), wb = Set(contentWords(b.title))
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count) >= 0.75
    }
}
