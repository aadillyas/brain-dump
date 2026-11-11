#if canImport(FoundationModels)
import BrainDumpCore
import Foundation
import FoundationModels

public enum AppleLLMError: LocalizedError {
    case unavailable(String)
    case unsupportedTurns

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Apple's on-device model is unavailable: \(reason)."
        case .unsupportedTurns: return "AppleLLM needs a final user turn."
        }
    }
}

/// Apple's on-device system model through the Foundation Models framework.
///
/// It reads the same instructions, few-shot examples and numbered lines as LocalLLM (`LinePrompt`). Guided generation replaces
/// GBNF, and the answer is rendered back into LinePrompt's text format so the same parser and validator
/// score it. The schema is built at runtime (no `@Generable` macro, which the Command Line Tools cannot
/// expand) and fixes the answer to exactly one entry per line.
@available(macOS 26.0, iOS 26.0, *)
public struct AppleLLM: LLMProvider {
    public struct Options: Sendable {
        /// Ask for each line's first words before its label, like the grammar's echo.
        public var echo = true
        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// nil when the model can be used; otherwise a short reason.
    public static var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off"
        case .unavailable(.deviceNotEligible): return "this Mac does not support Apple Intelligence"
        case .unavailable(.modelNotReady): return "the model is still downloading"
        case .unavailable(let reason): return String(describing: reason)
        }
    }

    public static var isAvailable: Bool { availability == nil }

    public func complete(turns: [ChatTurn], grammar: String?, maxTokens: Int) async throws -> String {
        if let reason = Self.availability { throw AppleLLMError.unavailable(reason) }
        guard let last = turns.last, last.role == .user else { throw AppleLLMError.unsupportedTurns }

        // Few-shot turns become worked examples in the instructions; the session holds no history.
        var instructions = turns.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let shots = turns.dropLast().filter { $0.role != .system }
        if !shots.isEmpty {
            instructions += "\n\nExamples:"
            for turn in shots {
                instructions += turn.role == .user ? "\n\nLines:\n\(turn.content)" : "\nAnswer:\n\(turn.content)"
            }
        }

        let session = LanguageModelSession(model: .default, instructions: instructions)
        if let grammar, grammar.contains("rel ::=") {
            return try await judge(session: session, prompt: last.content, grammar: grammar, maxTokens: maxTokens)
        }
        let lineCount = last.content.split(separator: "\n").filter { $0.first?.isNumber == true }.count
        let response = try await session.respond(
            to: "Lines:\n\(last.content)",
            schema: try Self.schema(lineCount: max(lineCount, 1), kinds: Self.kinds(in: grammar), echo: options.echo),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens * 2))
        let entries = try response.content.value([GeneratedContent].self, forProperty: "lines")
        let lines = Self.numberedLines(last.content)
        var used = Set<Int>()
        return try entries.enumerated().map { index, entry in
            let start = options.echo ? try entry.value(String.self, forProperty: "start") : ""
            // Which line this answer is about: the line its echoed first words came from. The model sometimes
            // skips or repeats a line, shifting every later answer, so neither position nor its own line
            // number can be trusted alone. Position is the fallback when the echo matches nothing well.
            let line = Self.align(echo: start, position: index + 1, lines: lines, used: used)
            used.insert(line)
            let label = try entry.value(String.self, forProperty: "label")
            let head = "\(line). \(start) -> "
            guard label != "skip" else { return head + "skip" }
            let title = try entry.value(String.self, forProperty: "title")
            let when = try entry.value(String.self, forProperty: "when")
            return head + "\(label) | \(title) | \(when)"
        }.joined(separator: "\n")
    }

    /// The numbered lines of a user turn (`1. text`), by number.
    static func numberedLines(_ text: String) -> [Int: String] {
        var out: [Int: String] = [:]
        for raw in text.split(separator: "\n") {
            guard let dot = raw.firstIndex(of: "."), let n = Int(raw[..<dot]) else { continue }
            out[n] = String(raw[raw.index(after: dot)...])
        }
        return out
    }

    /// The line whose first words best match `echo`: at least two of the first six words in common, ties
    /// broken by closeness to `position`, lines already answered avoided. Falls back to `position`.
    static func align(echo: String, position: Int, lines: [Int: String], used: Set<Int>) -> Int {
        func words(_ s: String, _ n: Int) -> [String] {
            Array(s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init).prefix(n))
        }
        let echoWords = words(echo, 6)
        guard !echoWords.isEmpty else { return position }
        var best = (line: position, score: 1, distance: Int.max)
        for (n, text) in lines where !used.contains(n) {
            let lineWords = words(text, 6)
            // Count matches in order, so "I need to" at the start of many lines does not dominate.
            var score = 0
            for (a, b) in zip(echoWords, lineWords) where a == b { score += 1 }
            let distance = abs(n - position)
            if score > best.score || (score == best.score && score > 1 && distance < best.distance) {
                best = (n, score, distance)
            }
        }
        return best.score > 1 ? best.line : position
    }

    /// Matcher's format: one `{relation, reason}` per candidate note, rendered as `N. same | reason`.
    private func judge(session: LanguageModelSession, prompt: String, grammar: String, maxTokens: Int) async throws -> String {
        let count = max(1, grammar.split(separator: "\n").filter { $0.hasPrefix("m") && $0.contains("::=") }.count)
        let entry = DynamicGenerationSchema(
            name: "Judgement",
            properties: [
                .init(name: "relation", description: "same, related or unrelated.",
                      schema: DynamicGenerationSchema(name: "Relation", anyOf: ["same", "related", "unrelated"])),
                .init(name: "reason", description: "At most 12 words; empty when unrelated.",
                      schema: DynamicGenerationSchema(type: String.self)),
            ])
        let root = DynamicGenerationSchema(
            name: "Answer",
            properties: [
                .init(name: "notes", description: "One judgement per numbered note, in order.",
                      schema: DynamicGenerationSchema(arrayOf: entry, minimumElements: count, maximumElements: count))
            ])
        let response = try await session.respond(
            to: prompt, schema: try GenerationSchema(root: root, dependencies: []),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens * 2))
        let entries = try response.content.value([GeneratedContent].self, forProperty: "notes")
        return try entries.enumerated().map { index, e in
            let relation = try e.value(String.self, forProperty: "relation")
            let reason = try e.value(String.self, forProperty: "reason")
            return relation == "unrelated" ? "\(index + 1). unrelated" : "\(index + 1). \(relation) | \(reason)"
        }.joined(separator: "\n")
    }

    /// The category ids allowed by LinePrompt's grammar (`kind ::= "todo" | "event" ...`), so the schema
    /// offers exactly the same labels; the built-in ids when there is no grammar.
    static func kinds(in grammar: String?) -> [String] {
        guard let line = grammar?.split(separator: "\n").first(where: { $0.hasPrefix("kind ::=") }) else {
            return ItemCategory.defaults.map(\.id)
        }
        return line.dropFirst("kind ::=".count).split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// Mirrors the GBNF line format `N. first words -> skip | kind | title | when`. Properties are generated
    /// in order, so `start` plays the role of the grammar's echo of the line's first words.
    static func schema(lineCount: Int, kinds: [String], echo: Bool) throws -> GenerationSchema {
        var properties: [DynamicGenerationSchema.Property] = []
        if echo {
            properties += [
                .init(name: "line", description: "The line number being labeled, in order.",
                      schema: DynamicGenerationSchema(type: Int.self)),
                .init(name: "start", description: "The first five words of that line, copied exactly.",
                      schema: DynamicGenerationSchema(type: String.self)),
            ]
        }
        properties += [
            .init(name: "label", description: "skip, or the kind of item this line holds.",
                  schema: DynamicGenerationSchema(name: "Kind", anyOf: ["skip"] + kinds)),
            .init(name: "title", description: "Required unless skip: a short command, or a short noun phrase naming the subject.",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "when", description: "Words from the line that say when, or empty.",
                  schema: DynamicGenerationSchema(type: String.self)),
        ]
        let label = DynamicGenerationSchema(name: "LineLabel", properties: properties)
        let answer = DynamicGenerationSchema(
            name: "Answer",
            properties: [
                .init(name: "lines", description: "One entry per numbered line, in order.",
                      schema: DynamicGenerationSchema(arrayOf: label, minimumElements: lineCount, maximumElements: lineCount))
            ])
        return try GenerationSchema(root: answer, dependencies: [])
    }
}

extension ExtractorOptions {
    /// Apple's model has a 4K context and pays per call, so it reads bigger chunks: fewer calls,
    /// and recall rose from 90% to 92% on the dev fixtures with precision unchanged.
    public static var appleOnDevice: ExtractorOptions {
        var options = ExtractorOptions()
        options.maxChunkWords = 220
        options.maxChunkLines = 16
        return options
    }
}

/// Tries Apple's model chunk by chunk and falls back to a local GGUF model for any chunk it fails on
/// (guardrail refusals, context overflow, the model becoming unavailable).
@available(macOS 26.0, iOS 26.0, *)
public struct FallbackLLM: LLMProvider {
    public let primary: AppleLLM
    public let fallback: LocalLLM?

    public init(primary: AppleLLM, fallback: LocalLLM?) {
        self.primary = primary
        self.fallback = fallback
    }

    public func complete(turns: [ChatTurn], grammar: String?, maxTokens: Int) async throws -> String {
        do {
            return try await primary.complete(turns: turns, grammar: grammar, maxTokens: maxTokens)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let fallback else { throw error }
            return try await fallback.complete(turns: turns, grammar: grammar, maxTokens: maxTokens)
        }
    }
}
#endif
