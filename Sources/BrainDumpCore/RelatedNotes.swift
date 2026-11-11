import Foundation
import NaturalLanguage

public struct RelatedNote: Identifiable, Sendable, Equatable {
    public let title: String
    /// e.g. "Ideas/morning-walks"
    public let wikiLink: String
    public let url: URL
    public let score: Double
    public var id: URL { url }
}

/// Finds existing Ideas/ and Thoughts/ notes related to a new idea or thought.
public enum RelatedNotes {
    static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "have", "has", "had", "was", "were", "are", "but", "not",
        "you", "your", "its", "it's", "from", "they", "them", "then", "than", "there", "their", "what", "when",
        "which", "who", "will", "would", "could", "should", "can", "just", "about", "into", "out", "over",
        "some", "any", "all", "been", "being", "get", "got", "need", "want", "like", "really", "very", "also",
        "maybe", "thing", "things", "something", "think", "feel", "how", "why", "our", "his", "her", "she",
        "him", "one", "too", "more", "most", "much", "make", "made", "does", "did", "doing", "i'm", "i've",
        "don't", "didn't", "isn't", "because", "while", "where", "these", "those", "here", "again", "still",
    ]

    /// Lowercased content words: three or more letters, not a stopword.
    public static func keywords(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }) {
            let w = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if w.count >= 3, !stopwords.contains(w) { out.insert(w) }
        }
        return out
    }

    /// Shared keywords over the size of the smaller set, 0 to 1.
    public static func keywordScore(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    /// Minimum keyword score (with at least two shared words) when no embedding is available.
    public static let keywordThreshold = 0.25
    /// Minimum combined score when the sentence embedding is available.
    public static let combinedThreshold = 0.4

    /// Combines semantic similarity (nil when unavailable) with keyword overlap. Returns nil below the threshold.
    public static func score(keywordScore kw: Double, sharedKeywords shared: Int, cosine: Double?) -> Double? {
        guard shared >= 1 else { return nil }
        if let cosine {
            // Sentence embeddings rate related text only around 0.4 and unrelated text near 0, so rescale before mixing.
            let semantic = max(0, min(1, (cosine - 0.15) / 0.5))
            let s = 0.6 * semantic + 0.4 * kw
            return s >= combinedThreshold ? s : nil
        }
        return shared >= 2 && kw >= keywordThreshold ? kw : nil
    }

    public static func find(title: String, quote: String, root: URL, excluding: URL? = nil, limit: Int = 3) -> [RelatedNote] {
        let query = title + ". " + quote
        let queryWords = keywords(query)
        guard !queryWords.isEmpty else { return [] }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        var scored: [RelatedNote] = []
        for folder in ["Ideas", "Thoughts"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "md" && url.resolvingSymlinksInPath() != excluding?.resolvingSymlinksInPath() {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let (noteTitle, body) = parse(raw, fallback: url.deletingPathExtension().lastPathComponent)
                let text = noteTitle + ". " + body
                let words = keywords(text)
                var cosine: Double?
                if let embedding {
                    let d = embedding.distance(between: query, and: String(text.prefix(600)), distanceType: .cosine)
                    if d.isFinite, d <= 2 { cosine = 1 - d }
                }
                if let s = score(keywordScore: keywordScore(queryWords, words), sharedKeywords: queryWords.intersection(words).count, cosine: cosine) {
                    scored.append(RelatedNote(
                        title: noteTitle, wikiLink: "\(folder)/\(url.deletingPathExtension().lastPathComponent)", url: url, score: s))
                }
            }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Strips frontmatter, the Related section and the trailing "From [[...]]" line; title is the first "# " heading.
    public static func parse(_ raw: String, fallback: String) -> (title: String, body: String) {
        var lines = raw.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines = Array(lines[(end + 1)...]) }
        var title = fallback
        var body: [String] = []
        var seenTitle = false
        for line in lines {
            if line.hasPrefix("## Related") { break }
            if !seenTitle, line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                seenTitle = true
            } else if !line.hasPrefix("From [[") {
                body.append(line)
            }
        }
        return (title, body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
