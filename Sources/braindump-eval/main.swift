import BrainDumpCore
import BrainDumpLLM
import Foundation

struct GoldDue: Decodable {
    var day: String
    var time: String?
}

struct GoldItem: Decodable {
    var kind: ItemKind
    var keywords: [String]
    var due: GoldDue?
    var alt: [ItemKind]?
}

struct Fixture: Decodable {
    var id: String
    var split: String
    var now: String
    var text: String
    var gold: [GoldItem]
}

struct Args {
    var model = ModelCatalog.defaultModel.id
    var split = "dev"
    var verbose = false
    var fixtures = "Evals/fixtures.json"
    var only: String?
    var noCache = false
    var checkCache = false
    var resolve: [String] = []
    var style: ExtractorOptions.Style?
    var now: String?

    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--model": model = it.next() ?? model
            case "--split": split = it.next() ?? split
            case "--verbose", "-v": verbose = true
            case "--fixtures": fixtures = it.next() ?? fixtures
            case "--only": only = it.next()
            case "--no-cache": noCache = true
            case "--check-cache": checkCache = true
            case "--resolve": if let p = it.next() { resolve.append(p) }
            case "--now": now = it.next()
            case "--style": style = it.next().flatMap(ExtractorOptions.Style.init(rawValue:))
            default:
                print("""
                usage: braindump-eval [--model <id>|cloud] [--split dev|holdout|all] [--verbose] [--only <fixture id>]
                                      [--fixtures <path>] [--no-cache] [--check-cache] [--style items|lines]
                models: \(ModelCatalog.all.map(\.id).joined(separator: ", "))
                """)
                exit(a == "--help" || a == "-h" ? 0 : 2)
            }
        }
    }
}

struct Score {
    var gold = 0, predicted = 0, matched = 0, kindOK = 0, dateScored = 0, dateOK = 0, rejected = 0
    var seconds = 0.0, generated = 0, generateSeconds = 0.0

    static func + (a: Score, b: Score) -> Score {
        Score(gold: a.gold + b.gold, predicted: a.predicted + b.predicted, matched: a.matched + b.matched,
              kindOK: a.kindOK + b.kindOK, dateScored: a.dateScored + b.dateScored, dateOK: a.dateOK + b.dateOK,
              rejected: a.rejected + b.rejected, seconds: a.seconds + b.seconds, generated: a.generated + b.generated,
              generateSeconds: a.generateSeconds + b.generateSeconds)
    }

    func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "   -" : String(format: "%3.0f%%", 100 * Double(n) / Double(d)) }

    func row(_ name: String) -> String {
        let tps = generateSeconds > 0 ? Double(generated) / generateSeconds : 0
        return name.padding(toLength: 22, withPad: " ", startingAt: 0)
            + String(format: " %4d %4d %4d", gold, predicted, matched)
            + "  " + pct(matched, gold) + "  " + pct(matched, predicted)
            + "  " + pct(kindOK, matched) + "  " + pct(dateOK, dateScored)
            + String(format: " %5d %7.1f %6.1f", rejected, seconds, tps)
    }

    static let header = "fixture                gold pred  hit  recall  prec  kind  date  rejct    secs  tok/s"
}

func timeZone(fromISO s: String) -> TimeZone {
    if s.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)! }
    let tail = s.suffix(6)
    guard let sign = tail.first, sign == "+" || sign == "-" else { return .current }
    let parts = tail.dropFirst().split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return .current }
    let seconds = (parts[0] * 3600 + parts[1] * 60) * (sign == "-" ? -1 : 1)
    return TimeZone(secondsFromGMT: seconds) ?? .current
}

func dayString(_ date: Date, _ calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

func timeString(_ date: Date, _ calendar: Calendar) -> String {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", c.hour!, c.minute!)
}

func describeDue(_ item: ExtractedItem, _ calendar: Calendar) -> String {
    guard let due = item.due else { return "-" }
    return dayString(due, calendar) + (item.dueHasTime ? " " + timeString(due, calendar) : "")
}

func dateMatches(_ item: ExtractedItem, _ gold: GoldDue?, _ calendar: Calendar) -> Bool {
    guard let gold else { return item.due == nil }
    guard let due = item.due, dayString(due, calendar) == gold.day else { return false }
    if let time = gold.time { return item.dueHasTime && timeString(due, calendar) == time }
    return true
}

func evaluate(_ f: Fixture, _ result: ExtractionResult, calendar: Calendar, verbose: Bool) -> Score {
    var score = Score(gold: f.gold.count, predicted: result.items.count, rejected: result.rejected.count)
    var goldTaken = Set<Int>()
    var lines: [String] = []
    for item in result.items {
        let cited = item.quote.lowercased()
        let candidates = f.gold.indices.filter { g in f.gold[g].keywords.allSatisfy { cited.contains($0.lowercased()) } }
        let tag: String
        if let g = candidates.first(where: { !goldTaken.contains($0) }) {
            goldTaken.insert(g)
            score.matched += 1
            let gold = f.gold[g]
            let kindOK = item.kind == gold.kind || (gold.alt ?? []).contains(item.kind)
            if kindOK { score.kindOK += 1 }
            var dateTag = ""
            // Dates are scored only when the kind is exactly the gold kind: an alternate kind implies a different date rule.
            if item.kind == gold.kind {
                score.dateScored += 1
                if dateMatches(item, gold.due, calendar) { score.dateOK += 1 } else {
                    dateTag = " DATE(want \(gold.due.map { $0.day + ($0.time.map { " " + $0 } ?? "") } ?? "-"))"
                }
            }
            tag = "HIT  [\(gold.keywords.joined(separator: ","))]" + (kindOK ? "" : " KIND(want \(gold.kind.rawValue))") + dateTag
        } else {
            tag = candidates.isEmpty ? "FP" : "DUP"
        }
        lines.append("  \(tag)  \(item.kind.rawValue): \(item.title)  due=\(describeDue(item, calendar))"
            + (item.whenText.map { " when=\"\($0)\"" } ?? "") + (item.lowConfidence ? " LOWCONF" : "")
            + "\n        \(item.sentenceIndices) \(item.quote.prefix(160))")
    }
    for (g, gold) in f.gold.enumerated() where !goldTaken.contains(g) {
        lines.append("  MISS [\(gold.keywords.joined(separator: ","))] \(gold.kind.rawValue)")
    }
    if verbose {
        lines.forEach { print($0) }
        result.rejected.forEach { print("  REJECTED \($0)") }
    }
    return score
}

func run() async throws {
    let args = Args()
    if !args.resolve.isEmpty {
        let iso = args.now ?? ISO8601DateFormatter().string(from: Date())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(fromISO: iso)
        let resolver = DateResolver(now: ISO8601DateFormatter().date(from: iso)!, calendar: calendar)
        for phrase in args.resolve {
            let r = resolver.resolve(phrase).map { dayString($0.date, calendar) + ($0.hasTime ? " " + timeString($0.date, calendar) : "") }
            let f = resolver.firstDate(in: phrase).map { "\"\($0.phrase)\" " + dayString($0.resolved.date, calendar) + ($0.resolved.hasTime ? " " + timeString($0.resolved.date, calendar) : "") }
            print("\(phrase.debugDescription): resolve=\(r ?? "nil") firstDate=\(f ?? "nil")")
        }
        return
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: args.fixtures))
    var fixtures = try JSONDecoder().decode([Fixture].self, from: data)
    if args.split != "all" { fixtures = fixtures.filter { $0.split == args.split } }
    if let only = args.only { fixtures = fixtures.filter { $0.id == only } }

    let provider: any LLMProvider
    var local: LocalLLM?
    if args.model == "cloud" {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            print("ANTHROPIC_API_KEY is not set"); exit(2)
        }
        provider = CloudLLM(apiKey: key)
    } else {
        guard let model = ModelCatalog.model(id: args.model) else { print("unknown model \(args.model)"); exit(2) }
        if !ModelCatalog.isDownloaded(model) {
            print("downloading \(model.name) (\(model.sizeMB) MB)...")
            let last = LockedInt()
            try await ModelCatalog.download(model) { p in
                let pct = Int(p * 100)
                if last.exchange(pct) / 10 != pct / 10 { print("  \(pct)%") }
            }
        }
        let llm = LocalLLM(modelPath: ModelCatalog.localURL(for: model))
        if args.noCache { await llm.setPrefixCache(false) }
        local = llm
        provider = llm
    }

    print("model \(args.model)  split \(args.split)  fixtures \(fixtures.count)")
    print(Score.header)
    var total = Score()
    var cacheMismatches = 0
    for f in fixtures {
        let now = ISO8601DateFormatter().date(from: f.now)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(fromISO: f.now)
        var extractor = Extractor(provider: provider, now: now, calendar: calendar)
        extractor.options.style = args.style
        await local?.resetStats()
        let start = Date()
        let result = try await extractor.extract(f.text)
        let seconds = Date().timeIntervalSince(start)
        if args.verbose { print("\(f.id) (\(f.text.split(separator: " ").count) words, \(result.sentences.count) sentences)") }
        var score = evaluate(f, result, calendar: calendar, verbose: args.verbose)
        score.seconds = seconds
        if let stats = await local?.stats() {
            score.generated = stats.generatedTokens
            score.generateSeconds = stats.generateSeconds
            if args.verbose {
                print(String(format: "  prompt %d tokens (%d reused) %.1fs, generated %d tokens %.1fs, load %.1fs",
                             stats.promptTokens, stats.reusedTokens, stats.promptSeconds, stats.generatedTokens,
                             stats.generateSeconds, stats.loadSeconds))
            }
        }
        if args.checkCache, let local {
            await local.setPrefixCache(false)
            let plain = try await extractor.extract(f.text)
            await local.setPrefixCache(true)
            let a = result.items.map { "\($0.kind)|\($0.title)|\($0.sentenceIndices)|\(String(describing: $0.due))" }
            let b = plain.items.map { "\($0.kind)|\($0.title)|\($0.sentenceIndices)|\(String(describing: $0.due))" }
            if a != b {
                cacheMismatches += 1
                print("  CACHE MISMATCH in \(f.id):\n    cached \(a)\n    plain  \(b)")
            }
        }
        print(score.row("\(f.id) (\(f.split))"))
        total = total + score
    }
    print(total.row("TOTAL"))
    if args.checkCache { print("prefix cache check: \(cacheMismatches == 0 ? "identical outputs" : "\(cacheMismatches) fixtures differ")") }
    await local?.unload()
}

final class LockedInt: @unchecked Sendable {
    private var value = -1
    private let lock = NSLock()
    func exchange(_ v: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = v
        return old
    }
}

do {
    try await run()
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
