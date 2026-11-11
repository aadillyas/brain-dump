import BrainDumpCore
import Foundation

/// The model labels every line in order, either `N. skip` or `N. kind | title | when`.
/// The grammar fixes the line numbers, so the model cannot cite the wrong line or invent one,
/// and skipping is the cheapest thing it can write.
public enum LinePrompt {
    public static let maxTitleChars = 80
    public static let maxWhenChars = 40
    /// Lines with fewer words are forced to "skip" by the grammar ("Morning.", "Right, go.").
    public static let minWords = 3
    /// Each answer line starts with this many words of its source line, forced by the grammar,
    /// so the model always sees which line it is labeling.
    public static let echoWords = 5

    /// The instructions, built from the user's categories.
    public static func system(_ categories: [ItemCategory]) -> String {
        var out = """
        You read numbered lines from a spoken morning brain dump. Answer every line in order: its number, its first words, then -> and either skip or one item about that line.
        Most lines are just talk: skip them.

        """
        for c in categories {
            out += "\(c.id) = \(c.definition)"
            if !c.examples.isEmpty { out += " E.g. " + c.examples.map { "\"\($0)\"" }.joined(separator: " ") }
            out += "\n"
        }
        out += """
        Always skip: things already done, things that happened in the past, other people's jobs, wishes and plans that are only maybe or someday (one day, would be nice, we'll see), filler.
        Item format: kind | title | when. The title is a short command for something to do; for a note, a short noun phrase naming its subject (the project, person or theme). When is the words from the line that say when, or nothing.
        """
        return out
    }

    /// Labels use the built-in category ids; a label whose category is disabled or deleted becomes skip.
    static let examples: [(lines: [String], answer: [String])] = [
        ([
            "Okay so it's Tuesday, I slept badly again, um, the neighbor's dog was barking at like four.",
            "First thing, I need to send the invoice to Marco before noon because he's been chasing me.",
            "Oh and I have to pick up my prescription from the pharmacy on the way home.",
            "I already booked the flights for March, so that's done.",
            "Then there's the call with the landlord at four about the lease.",
            "Sara said she'd handle the client deck, so not my problem.",
            "What if we made the onboarding a little game, like a quest map for new users?",
        ], [
            "skip",
            "todo | Send the invoice to Marco | before noon",
            "todo | Pick up prescription from the pharmacy |",
            "skip",
            "event | Call with the landlord about the lease | at four",
            "skip",
            "note | Onboarding as a quest map game |",
        ]),
        ([
            "Right, personal stuff.",
            "I finally called the bank yesterday and sorted out the card thing.",
            "Lucy's going to book the restaurant for Friday, she said she's on it.",
            "It would be nice to go to Japan one day, maybe.",
            "Oh, I need to renew the car insurance before the twelfth.",
            "Honestly I think I'm more tired than I admit, and it's starting to show at work.",
            "Anyway, coffee's ready.",
        ], [
            "skip",
            "skip",
            "skip",
            "skip",
            "todo | Renew the car insurance | before the twelfth",
            "note | More tired than I admit |",
            "skip",
        ]),
        ([
            "Yesterday was honestly a lot, the meeting ran two hours over.",
            "I got the report out in the end though, which, yeah, good.",
            "It's Mum's birthday on Saturday, so I need to order her flowers by Thursday.",
            "Uh, the printer's broken again but Dave said he'd call the repair guy.",
            "The dentist moved me to Thursday at ten, so that's in.",
            "And I should, no wait, I need to finish the Q3 slides for the Friday review.",
            "What if the team wiki had a page of small wins every week?",
        ], [
            "skip",
            "skip",
            "todo | Order flowers for Mum's birthday | by Thursday",
            "skip",
            "event | Dentist appointment | Thursday at ten",
            "todo | Finish the Q3 slides | Friday",
            "note | Weekly small wins page on the team wiki |",
        ]),
    ]

    static func numbered(_ lines: [String]) -> String {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    static func echo(_ line: String) -> String {
        let words = line.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(echoWords).joined(separator: " ") + (words.count > echoWords ? "..." : "")
    }

    static func answer(_ lines: [String], _ labels: [String]) -> String {
        zip(lines, labels).enumerated().map { "\($0.offset + 1). \(echo($0.element.0)) -> \($0.element.1)" }
            .joined(separator: "\n")
    }

    public static func turns(for lines: [String], categories: [ItemCategory] = ItemCategory.defaults) -> [ChatTurn] {
        var turns = [ChatTurn(.system, system(categories))]
        let ids = Set(categories.map(\.id))
        for example in examples {
            let labels = example.answer.map { label in
                let kind = label.split(separator: " ").first.map(String.init) ?? "skip"
                return kind == "skip" || ids.contains(kind) ? label : "skip"
            }
            turns.append(ChatTurn(.user, numbered(example.lines)))
            turns.append(ChatTurn(.assistant, answer(example.lines, labels)))
        }
        turns.append(ChatTurn(.user, numbered(lines)))
        return turns
    }

    static func wordCount(_ line: String) -> Int {
        line.split(whereSeparator: { $0.isWhitespace }).count
    }

    public static func grammar(for lines: [String], categories: [ItemCategory] = ItemCategory.defaults) -> String {
        var rules: [String] = []
        let names = lines.indices.map { "l\($0 + 1)" }
        rules.append("root ::= " + names.joined(separator: " \"\\n\" "))
        for (i, line) in lines.enumerated() {
            let body = wordCount(line) < minWords ? "\"skip\"" : "entry"
            let prefix = "\(i + 1). \(echo(line)) -> "
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            rules.append("l\(i + 1) ::= \"\(prefix)\" \(body)")
        }
        rules.append(contentsOf: [
            "entry ::= \"skip\" | kind \" | \" title \" |\" when",
            "kind ::= " + categories.map { "\"\($0.id)\"" }.joined(separator: " | "),
            "title ::= [^| \\n] tchar{0,\(maxTitleChars - 1)}",
            "when ::= ( \" \" [^| \\n] tchar{0,\(maxWhenChars - 1)} )?",
            "tchar ::= [^|\\n]",
        ])
        return rules.joined(separator: "\n")
    }

    struct Label {
        var line: Int
        var kind: String
        var title: String
        var when: String
    }

    /// Items from the model's answer; skipped lines are left out.
    static func parse(_ output: String, lineCount: Int) -> [Label]? {
        var labels: [Label] = []
        var seen = 0
        for raw in output.split(separator: "\n") {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard let dot = text.firstIndex(of: "."), let n = Int(text[..<dot]) else { continue }
            seen += 1
            var rest = Substring(text[text.index(after: dot)...])
            if let arrow = rest.range(of: " -> ") { rest = rest[arrow.upperBound...] }
            let label = rest.trimmingCharacters(in: .whitespaces)
            if label == "skip" { continue }
            let parts = label.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            labels.append(Label(line: n, kind: parts[0], title: parts[1], when: parts.count > 2 ? parts[2] : ""))
        }
        return seen == 0 && lineCount > 0 ? nil : labels
    }
}
