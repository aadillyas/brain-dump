import BrainDumpCore
import Foundation

/// An existing topic note an item belongs to.
public struct TopicMatch: Sendable, Equatable {
    public let url: URL
    public let title: String
    /// Why, in a few words.
    public let reason: String

    public init(url: URL, title: String, reason: String) {
        self.url = url
        self.title = title
        self.reason = reason
    }
}

/// Decides which existing topic note an item belongs to, or nil for a new topic. The app files every note
/// through this one interface, so the implementation can change (today: similarity search plus an LLM
/// "same subject?" judgement; next: an embedding model plus a reranker, chosen on the matching eval)
/// without touching the dump flow.
public protocol TopicMatcher: Sendable {
    func match(title: String, text: String, root: URL) async -> TopicMatch?
}

/// Candidates from `RelatedNotes` (keywords plus sentence embedding), judged by the model with `Matcher`.
/// Only "same" judgements count: they were reliable in testing, while "related" was not.
public struct LLMTopicMatcher: TopicMatcher {
    public let provider: any LLMProvider
    public var folders = ["Notes"]
    public var maxCandidates = 4

    public init(provider: any LLMProvider) { self.provider = provider }

    public func match(title: String, text: String, root: URL) async -> TopicMatch? {
        let found = RelatedNotes.find(title: title, quote: text, root: root, folders: folders,
                                      limit: maxCandidates, minScore: RelatedNotes.candidateThreshold)
        guard !found.isEmpty else { return nil }
        let candidates = found.map { note -> (title: String, excerpt: String) in
            let raw = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            return (note.title, RelatedNotes.parse(raw, fallback: note.title).body)
        }
        guard let judged = try? await Matcher.judge(provider: provider, title: title, quote: text, candidates: candidates),
              let i = judged.firstIndex(where: { $0.relation == .same }) else { return nil }
        return TopicMatch(url: found[i].url, title: found[i].title, reason: judged[i].reason)
    }
}
