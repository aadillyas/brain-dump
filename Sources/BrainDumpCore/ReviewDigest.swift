import Foundation

/// What a stretch of dumps added up to: counts, the topics that kept coming up, captured actions, and topics gone quiet.
/// Pure data read from the notes folder; the periods are `from` inclusive, `to` exclusive.
public struct ReviewDigest: Sendable, Equatable {
    public struct Quote: Sendable, Equatable, Identifiable {
        public let date: Date
        public let text: String
        /// e.g. "Journal/2026-11-12#08:12"
        public let journalLink: String
        public let journalURL: URL
        public var id: String { journalLink + text }
    }

    public struct Topic: Sendable, Equatable, Identifiable {
        public let title: String
        public let url: URL
        /// Log entries inside the period.
        public let entriesInPeriod: Int
        public let totalMentions: Int
        /// In the period, newest first.
        public let quotes: [Quote]
        public let openTasks: [String]
        /// The note's `created` date (nil when missing), for "new this week".
        public let firstSeen: Date?
        public let isNew: Bool
        public let lastMentioned: Date
        public var id: URL { url }
    }

    public struct Action: Sendable, Equatable, Identifiable {
        /// Category name, e.g. "To-do", "Note added to".
        public let kind: String
        public let text: String
        public let day: Date
        public let id: String
    }

    public struct QuietTopic: Sendable, Equatable, Identifiable {
        public let title: String
        public let url: URL
        public let totalMentions: Int
        public let lastMentioned: Date
        public var id: URL { url }
    }

    public let from: Date
    public let to: Date
    public let dumps: Int
    public let words: Int
    public let daysJournaled: Int
    public let streak: Int
    public let topics: [Topic]
    public let actions: [Action]
    public let quiet: [QuietTopic]

    public static let quietMinMentions = 3
    public static let quietLookbackWeeks = 4

    public static func build(root: URL, from: Date, to: Date, calendar: Calendar = .current, today: Date = Date()) -> ReviewDigest {
        let all = JournalIndex.load(root: root, calendar: calendar)
        let inPeriod = all.filter { $0.date >= from && $0.date < to }
        let days = Set(inPeriod.map { calendar.startOfDay(for: $0.date) })
        let lookbackStart = calendar.date(byAdding: .weekOfYear, value: -quietLookbackWeeks, to: from) ?? from

        var topics: [Topic] = []
        var quiet: [QuietTopic] = []
        let notesDir = root.appendingPathComponent("Notes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "md" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let note = parseNote(raw, fallback: url.deletingPathExtension().lastPathComponent, root: root, calendar: calendar)
            let current = note.log.filter { $0.date >= from && $0.date < to }
            if !current.isEmpty {
                let created = note.created
                topics.append(Topic(
                    title: note.title, url: url, entriesInPeriod: current.count,
                    totalMentions: max(note.mentions, note.log.count),
                    quotes: current.sorted { $0.date > $1.date }, openTasks: note.openTasks, firstSeen: created,
                    isNew: created.map { $0 >= from && $0 < to } ?? false,
                    lastMentioned: current.map(\.date).max() ?? from))
            } else if max(note.mentions, note.log.count) >= quietMinMentions,
                      let last = note.log.map(\.date).max(),
                      note.log.contains(where: { $0.date >= lookbackStart && $0.date < from }) {
                quiet.append(QuietTopic(title: note.title, url: url, totalMentions: max(note.mentions, note.log.count), lastMentioned: last))
            }
        }
        topics.sort {
            $0.entriesInPeriod != $1.entriesInPeriod ? $0.entriesInPeriod > $1.entriesInPeriod : $0.lastMentioned > $1.lastMentioned
        }
        quiet.sort { $0.lastMentioned > $1.lastMentioned }

        return ReviewDigest(
            from: from, to: to, dumps: inPeriod.count, words: inPeriod.reduce(0) { $0 + $1.words },
            daysJournaled: days.count, streak: JournalIndex.streak(all, today: today, calendar: calendar),
            topics: topics, actions: actions(root: root, from: from, to: to, calendar: calendar), quiet: quiet)
    }

    // MARK: Journal actions

    static func actions(root: URL, from: Date, to: Date, calendar: Calendar) -> [Action] {
        let dir = root.appendingPathComponent("Journal", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Action] = []
        for url in files where url.pathExtension == "md" {
            let name = url.deletingPathExtension().lastPathComponent
            let p = name.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, let day = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])),
                  day >= calendar.startOfDay(for: from), day < to,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var inActions = false
            var n = 0
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("#") {
                    inActions = line.trimmingCharacters(in: .whitespaces) == "### Actions"
                } else if inActions, line.hasPrefix("- ") {
                    let item = String(line.dropFirst(2))
                    guard let colon = item.range(of: ": ") else { continue }
                    let kind = item[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
                    let body = item[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                    guard !kind.isEmpty, !body.isEmpty else { continue }
                    out.append(Action(kind: kind, text: body, day: day, id: "\(name)#\(n)"))
                    n += 1
                }
            }
        }
        return out.sorted { $0.day != $1.day ? $0.day > $1.day : $0.id < $1.id }
    }

    // MARK: Topic notes

    struct ParsedNote {
        var title: String
        var created: Date?
        var mentions = 1
        var openTasks: [String] = []
        var log: [Quote] = []
    }

    static func parseNote(_ raw: String, fallback: String, root: URL, calendar: Calendar) -> ParsedNote {
        var lines = raw.components(separatedBy: "\n")
        var note = ParsedNote(title: fallback)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for l in lines[1..<end] {
                if l.hasPrefix("created:") {
                    note.created = parseISO(String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces))
                } else if l.hasPrefix("mentions:") {
                    note.mentions = Int(l.dropFirst(9).trimmingCharacters(in: .whitespaces)) ?? 1
                }
            }
            lines = Array(lines[(end + 1)...])
        }
        var section = ""
        var seenTitle = false
        var current: (date: Date, link: String, quote: [String])?
        func flush() {
            if let c = current {
                let text = c.quote.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                let file = c.link.split(separator: "#").first.map(String.init) ?? c.link
                note.log.append(Quote(date: c.date, text: text, journalLink: c.link,
                                      journalURL: root.appendingPathComponent(file + ".md")))
            }
            current = nil
        }
        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                section = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else if !seenTitle, line.hasPrefix("# ") {
                note.title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                seenTitle = true
            } else if section == "Tasks", line.hasPrefix("- [ ] ") {
                var t = String(line.dropFirst(6))
                if let dot = t.range(of: " · [[") { t = String(t[..<dot.lowerBound]) }
                note.openTasks.append(t.trimmingCharacters(in: .whitespaces))
            } else if section == "Log" {
                if line.hasPrefix("### ") {
                    flush()
                    let rest = line.dropFirst(4)
                    let parts = rest.components(separatedBy: " · [[")
                    guard parts.count == 2, let date = parseStamp(parts[0], calendar: calendar) else { continue }
                    current = (date, parts[1].replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces), [])
                } else if line.hasPrefix(">"), current != nil {
                    current?.quote.append(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        flush()
        return note
    }

    static func parseStamp(_ s: String, calendar: Calendar) -> Date? {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    static func parseISO(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }
}
