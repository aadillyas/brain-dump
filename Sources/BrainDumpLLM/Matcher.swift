import BrainDumpCore
import Foundation

public enum NoteRelation: String, Sendable {
    /// The new item is about the same subject: its words belong in that note.
    case same
    /// A different subject with a real connection: link the two notes.
    case related
    case unrelated
}

public struct NoteJudgement: Sendable, Equatable {
    public let relation: NoteRelation
    /// Why, in a few words; empty for unrelated.
    public let reason: String
}

/// Asks the model how a new idea or reflection relates to a few candidate notes found by similarity search.
/// Output is one line per candidate, `N. same | reason`, constrained by a grammar (or Apple's guided generation).
public enum Matcher {
    public static let maxReasonChars = 80

    static let system = """
    You compare a new item from a morning brain dump with existing notes. Answer every note in order with one of:
    same = the new item is about the same subject, so its words belong in that note.
    related = a different subject with a real connection worth linking: part of the same project (a feature, problem or next step of it), the same person or place, or one causes the other.
    unrelated = no real connection; sharing a common word or a mood is not enough.
    For same or related, add | and a reason of at most 12 words naming the project, person or topic both notes are about. If you cannot name one that appears in both, answer unrelated.
    """

    static let example = (
        user: """
        New: Weekend hiking club
        "What if a few of us from work started a little weekend hiking club?"

        1. Team offsite outdoors: Maybe the next offsite could be outdoors, a hike or something.
        2. Hiking club: Start a small hiking group with people from work on Saturdays.
        3. Car insurance renewal: Renew the car insurance before the twelfth.
        4. Club newsletter: What if the hiking club had a little monthly newsletter with routes?
        """,
        answer: """
        1. related | both are about getting colleagues together outdoors
        2. same | the same work hiking group idea
        3. unrelated
        4. related | a feature of the hiking club idea
        """)

    public static func turns(title: String, quote: String, candidates: [(title: String, excerpt: String)]) -> [ChatTurn] {
        let list = candidates.enumerated().map { "\($0.offset + 1). \($0.element.title): \(oneLine($0.element.excerpt, 240))" }
        return [
            ChatTurn(.system, system),
            ChatTurn(.user, example.user),
            ChatTurn(.assistant, example.answer),
            ChatTurn(.user, "New: \(title)\n\"\(oneLine(quote, 300))\"\n\n" + list.joined(separator: "\n")),
        ]
    }

    public static func grammar(count: Int) -> String {
        let names = (1...max(1, count)).map { "m\($0)" }
        var rules = ["root ::= " + names.joined(separator: " \"\\n\" ")]
        for (i, name) in names.enumerated() { rules.append("\(name) ::= \"\(i + 1). \" answer") }
        rules += [
            "answer ::= \"unrelated\" | rel \" | \" reason",
            "rel ::= \"same\" | \"related\"",
            "reason ::= [^|\\n ] [^|\\n]{0,\(maxReasonChars - 1)}",
        ]
        return rules.joined(separator: "\n")
    }

    /// One judgement per candidate, in order. Unreadable lines count as unrelated.
    public static func parse(_ output: String, count: Int) -> [NoteJudgement] {
        var out = Array(repeating: NoteJudgement(relation: .unrelated, reason: ""), count: count)
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]), (1...count).contains(n) else { continue }
            let parts = line[line.index(after: dot)...].split(separator: "|", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let relation = parts.first.flatMap({ NoteRelation(rawValue: $0.lowercased()) }) else { continue }
            out[n - 1] = NoteJudgement(relation: relation, reason: relation == .unrelated ? "" : (parts.count > 1 ? parts[1] : ""))
        }
        return out
    }

    public static func judge(provider: any LLMProvider, title: String, quote: String,
                             candidates: [(title: String, excerpt: String)]) async throws -> [NoteJudgement] {
        guard !candidates.isEmpty else { return [] }
        let output = try await provider.complete(
            turns: turns(title: title, quote: quote, candidates: candidates),
            grammar: grammar(count: candidates.count), maxTokens: 40 * candidates.count)
        return parse(output, count: candidates.count)
    }

    static func oneLine(_ s: String, _ limit: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
