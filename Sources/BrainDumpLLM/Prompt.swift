import BrainDumpCore
import Foundation

/// Everything the model sees. The system prompt and few-shot turns are a fixed, byte-identical prefix
/// so LocalLLM can reuse their KV cache across chunks.
public enum ExtractionPrompt {
    public static let maxItemsPerChunk = 4
    public static let maxTitleChars = 80
    public static let maxWhenChars = 40

    static let system = """
    You read numbered lines from a spoken morning brain dump and pick out only what the speaker wants to keep. Most lines are just talk: they produce nothing.
    Kinds:
    task = work the speaker must do today or soon.
    reminder = a personal errand or thing the speaker must not forget.
    idea = a new creative or project idea the speaker wants to keep.
    thought = a reflection or worry worth keeping, not something to do.
    Skip anything already done, anything that happened in the past, other people's jobs, maybes and someday wishes.
    lines = the line numbers that say the item. title = a short command for a task or reminder, a short noun phrase for an idea or thought. when = words copied exactly from those lines saying when, or "".
    """

    static let examples: [(lines: [String], answer: String)] = [
        ([
            "Okay so it's Tuesday, I slept badly again, um, the neighbor's dog was barking at like four.",
            "First thing, I need to send the invoice to Marco before noon because he's been chasing me.",
            "Oh and I have to pick up my prescription from the pharmacy on the way home.",
            "I already booked the flights for March, so that's done.",
            "Sara said she'd handle the client deck, so not my problem.",
            "What if we made the onboarding a little game, like a quest map for new users?",
        ], #"{"items":[{"lines":[2],"kind":"task","title":"Send the invoice to Marco","when":"before noon"},{"lines":[3],"kind":"reminder","title":"Pick up prescription from the pharmacy","when":""},{"lines":[6],"kind":"idea","title":"Onboarding as a quest map game","when":""}]}"#),
        ([
            "Yesterday was honestly a lot, the meeting ran two hours over.",
            "I got the report out in the end though, which, yeah, good.",
            "Anyway, coffee's ready, um, let me think.",
            "Maybe someday I'll learn the piano, who knows.",
        ], #"{"items":[]}"#),
        ([
            "I keep feeling like I'm saying yes to too many things and it's eating my weekends.",
            "Mum's birthday is Saturday.",
            "I need to order her flowers by Thursday, the nice ones from that shop on Elm.",
            "Uh, the printer's broken again but Dave said he'd call the repair guy.",
            "And I should, no wait, I need to finish the Q3 slides for the Friday review.",
        ], #"{"items":[{"lines":[1],"kind":"thought","title":"Saying yes to too much is eating my weekends","when":""},{"lines":[2,3],"kind":"reminder","title":"Order flowers for Mum's birthday","when":"by Thursday"},{"lines":[5],"kind":"task","title":"Finish the Q3 slides","when":"Friday"}]}"#),
    ]

    public static func numbered(_ lines: [String]) -> String {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    public static func turns(for lines: [String]) -> [ChatTurn] {
        var turns = [ChatTurn(.system, system)]
        for example in examples {
            turns.append(ChatTurn(.user, numbered(example.lines)))
            turns.append(ChatTurn(.assistant, example.answer))
        }
        turns.append(ChatTurn(.user, numbered(lines)))
        return turns
    }

    /// GBNF for one chunk: line numbers limited to 1...lineCount, kinds to the four enums, bounded strings.
    public static func grammar(lineCount: Int) -> String {
        let n = max(1, lineCount)
        let lineAlts = (1...n).map { "\"\($0)\"" }.joined(separator: " | ")
        return """
        root ::= "{\\"items\\":[" ( item ( "," item ){0,\(maxItemsPerChunk - 1)} )? "]}"
        item ::= "{\\"lines\\":[" line ( "," line ){0,2} "],\\"kind\\":\\"" kind "\\",\\"title\\":\\"" title "\\",\\"when\\":\\"" when "\\"}"
        line ::= \(lineAlts)
        kind ::= "task" | "reminder" | "idea" | "thought"
        title ::= [^"\\\\\\n\\r\\t ] char{0,\(maxTitleChars - 1)}
        when ::= char{0,\(maxWhenChars)}
        char ::= [^"\\\\\\n\\r\\t]
        """
    }

    /// JSON schema equivalent to `grammar`, for providers that take structured-output schemas.
    /// Line ranges are checked by the validator.
    public static let jsonSchema = """
    {"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{\
    "lines":{"type":"array","items":{"type":"integer"}},\
    "kind":{"type":"string","enum":["task","reminder","idea","thought"]},\
    "title":{"type":"string"},\
    "when":{"type":"string"}},\
    "required":["lines","kind","title","when"],"additionalProperties":false}}},\
    "required":["items"],"additionalProperties":false}
    """
}
