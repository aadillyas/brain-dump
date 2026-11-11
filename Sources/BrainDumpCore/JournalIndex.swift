import Foundation

public struct JournalEntry: Identifiable, Sendable, Equatable {
    /// Day plus the section's HH:mm.
    public let date: Date
    public let url: URL
    public let preview: String
    public let words: Int
    public init(date: Date, url: URL, preview: String, words: Int) {
        self.date = date
        self.url = url
        self.preview = preview
        self.words = words
    }

    public var id: String { url.lastPathComponent + "#" + String(date.timeIntervalSince1970) }
}

/// Reads dumps back out of Journal/yyyy-MM-dd.md, one per `## HH:mm` section.
public enum JournalIndex {
    public static func load(root: URL, calendar: Calendar = .current) -> [JournalEntry] {
        let dir = root.appendingPathComponent("Journal", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [JournalEntry] = []
        for url in files where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out += entries(in: text, fileName: url.deletingPathExtension().lastPathComponent, url: url, calendar: calendar)
        }
        return out.sorted { $0.date > $1.date }
    }

    public static func entries(in text: String, fileName: String, url: URL, calendar: Calendar = .current) -> [JournalEntry] {
        let parts = fileName.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return [] }
        var out: [JournalEntry] = []
        var time: (Int, Int)?
        var body: [String] = []
        func flush() {
            guard let t = time,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: t.0, minute: t.1))
            else { return }
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let first = joined.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            out.append(JournalEntry(date: date, url: url, preview: first, words: joined.split(whereSeparator: \.isWhitespace).count))
        }
        var inActions = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                let hm = line.dropFirst(3).split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                time = hm.count == 2 ? (hm[0], hm[1]) : nil
                body = []
                inActions = false
            } else if line.hasPrefix("### ") || line.hasPrefix("# ") {
                inActions = true
            } else if time != nil, !inActions {
                body.append(line)
            }
        }
        flush()
        return out
    }

    /// Consecutive days with a dump, ending today. A missing today does not break a streak that ran through yesterday.
    public static func streak(_ entries: [JournalEntry], today: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(entries.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: today)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var n = 0
        while days.contains(day) {
            n += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return n
    }
}
