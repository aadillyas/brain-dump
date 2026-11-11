import Foundation
import NaturalLanguage

/// Splits a dump into sentences, then into chunks small enough for a tiny model to read whole.
public enum Segmenter {
    public static let maxSentenceWords = 45

    public static func sentences(in text: String) -> [Sentence] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var parts: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { parts.append(contentsOf: splitLong(piece)) }
            return true
        }
        return parts.enumerated().map { Sentence(index: $0.offset, text: $0.element) }
    }

    /// Speech often arrives as one run-on sentence. Break it at commas or "and" so no line is too long to cite.
    static func splitLong(_ sentence: String) -> [String] {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > maxSentenceWords else { return [sentence] }
        var pieces: [String] = []
        var current: [String] = []
        for word in words {
            let startsClause = ["and", "so", "but", "also", "then"].contains(word.lowercased())
            if current.count >= maxSentenceWords
                || (current.count >= maxSentenceWords / 2 && (startsClause || current.last?.hasSuffix(",") == true))
            {
                pieces.append(current.joined(separator: " "))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty {
            if current.count < 4, let last = pieces.popLast() {
                pieces.append(last + " " + current.joined(separator: " "))
            } else {
                pieces.append(current.joined(separator: " "))
            }
        }
        return pieces
    }

    /// Consecutive sentences grouped so each chunk stays under `maxWords`.
    public static func chunks(_ sentences: [Sentence], maxWords: Int = 110, maxLines: Int = 9) -> [[Sentence]] {
        var result: [[Sentence]] = []
        var current: [Sentence] = []
        var words = 0
        for sentence in sentences {
            let count = sentence.text.split(separator: " ").count
            if !current.isEmpty && (words + count > maxWords || current.count >= maxLines) {
                result.append(current)
                current = []
                words = 0
            }
            current.append(sentence)
            words += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
