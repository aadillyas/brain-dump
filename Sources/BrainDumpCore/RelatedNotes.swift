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

/// Finds existing notes related to a new idea or reflection.
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

    /// Lowercased content words: three or more letters, not a stopword, plural "s" dropped ("dumps" → "dump").
    /// Adjacent words are also joined, so "brain dump" matches "braindump".
    public static func keywords(_ text: String) -> Set<String> {
        var out = Set<String>()
        var previous: String?
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }) {
            let w = stem(String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'")))
            guard w.count >= 3, !stopwords.contains(w) else { previous = nil; continue }
            out.insert(w)
            if let previous { out.insert(previous + w) }
            previous = w
        }
        return out
    }

    static func stem(_ w: String) -> String {
        guard w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") else { return w }
        return String(w.dropLast())
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
    /// Looser threshold for candidates a model will judge (`Matcher`): recall matters, the model removes noise.
    public static let candidateThreshold = 0.1
    /// Added when the item shares a word with a note's title.
    public static let titleBonus = 0.15

    /// Combines semantic similarity (nil when unavailable) with keyword overlap. Returns nil below the threshold.
    /// `minScore` replaces `combinedThreshold`: lower it when a model judges the candidates afterwards.
    /// `titleHit`: the new item shares a word with the note's title, usually the project or person it is about.
    public static func score(keywordScore kw: Double, sharedKeywords shared: Int, cosine: Double?,
                             minScore: Double = combinedThreshold, titleHit: Bool = false) -> Double? {
        guard shared >= 1 else { return nil }
        let bonus = titleHit ? titleBonus : 0
        if let cosine {
            // Sentence embeddings rate related text only around 0.4 and unrelated text near 0, so rescale before mixing.
            let semantic = max(0, min(1, (cosine - 0.15) / 0.5))
            let s = 0.6 * semantic + 0.4 * kw + bonus
            return s >= minScore ? s : nil
        }
        return shared >= 2 && kw >= keywordThreshold ? kw : nil
    }

    /// `folders` are the notes folders to scan, relative to `root`.
    public static func find(title: String, quote: String, root: URL, folders: [String] = ItemCategory.defaults.noteFolders,
                            excluding: URL? = nil, limit: Int = 3, minScore: Double = combinedThreshold) -> [RelatedNote] {
        let query = title + ". " + quote
        let queryWords = keywords(query)
        guard !queryWords.isEmpty else { return [] }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        var scored: [RelatedNote] = []
        for folder in folders {
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
                if let s = score(keywordScore: keywordScore(queryWords, words), sharedKeywords: queryWords.intersection(words).count, cosine: cosine, minScore: minScore,
                                      titleHit: !queryWords.isDisjoint(with: keywords(noteTitle))) {
                    scored.append(RelatedNote(
                        title: noteTitle, wikiLink: "\(folder)/\(url.deletingPathExtension().lastPathComponent)", url: url, score: s))
                }
            }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Strips frontmatter, the Related section, log headings, quote markers and the old trailing "From [[...]]" line;
    /// title is the first "# " heading.
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
            } else if line.hasPrefix("> ") {
                body.append(String(line.dropFirst(2)))
            } else if !line.hasPrefix("From [[") && !line.hasPrefix("### ") && line != "## Log" {
                body.append(line)
            }
        }
        return (title, body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
