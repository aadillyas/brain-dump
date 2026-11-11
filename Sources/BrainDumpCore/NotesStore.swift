import Foundation

public struct NotesStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// ~/BrainDump
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BrainDump", isDirectory: true)
    }

    /// Creates root, Journal/, Ideas/ and Thoughts/ if missing.
    public func prepare() throws {
        for sub in ["", "Journal", "Ideas", "Thoughts"] {
            try FileManager.default.createDirectory(
                at: sub.isEmpty ? root : root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    /// Writes Journal/yyyy-MM-dd.md, or appends a "## HH:mm" section if the day already has one.
    public func writeJournal(text: String, date: Date) throws -> NoteRef {
        try prepare()
        let day = Self.format(date, "yyyy-MM-dd")
        let time = Self.format(date, "HH:mm")
        let url = root.appendingPathComponent("Journal/\(day).md")
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var content: String
        if FileManager.default.fileExists(atPath: url.path) {
            content = try String(contentsOf: url, encoding: .utf8)
            content = content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## \(time)\n\n\(body)\n"
        } else {
            let heading = Self.format(date, "EEEE d MMMM yyyy")
            content = "---\ndate: \(day)\ntype: journal\n---\n\n# \(heading)\n\n## \(time)\n\n\(body)\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return NoteRef(url: url, wikiLink: "Journal/\(day)")
    }

    /// Creates Ideas/<slug>.md or Thoughts/<slug>.md with frontmatter and a link back to the journal.
    public func createNote(kind: ItemKind, title: String, body: String, journal: NoteRef, date: Date) throws -> NoteRef {
        try prepare()
        let folder = kind == .idea ? "Ideas" : "Thoughts"
        let type = kind == .idea ? "idea" : "thought"
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        let slug = Self.slug(title)
        var name = slug
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + ".md").path) {
            name = "\(slug)-\(n)"
            n += 1
        }
        let heading = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let created = Self.isoFormatter().string(from: date)
        let content = """
            ---
            type: \(type)
            created: \(created)
            source: "[[\(journal.wikiLink)]]"
            ---

            # \(heading)

            \(body.trimmingCharacters(in: .whitespacesAndNewlines))

            From [[\(journal.wikiLink)]]

            """
        let url = dir.appendingPathComponent(name + ".md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return NoteRef(url: url, wikiLink: "\(folder)/\(name)")
    }

    /// Appends an "Actions" list to the journal entry written by `writeJournal`.
    public func appendActions(_ lines: [String], to journal: NoteRef) throws {
        guard !lines.isEmpty else { return }
        var content = try String(contentsOf: journal.url, encoding: .utf8)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n### Actions\n\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try content.write(to: journal.url, atomically: true, encoding: .utf8)
    }

    /// Adds `- [[to]]` under a "## Related" section of `from`, creating the section if missing. No duplicates.
    public func addRelatedLink(from: NoteRef, to: NoteRef) throws {
        let link = "- [[\(to.wikiLink)]]"
        let content = try String(contentsOf: from.url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Related" }) {
            var end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
            if lines[(start + 1)..<end].contains(where: { $0.trimmingCharacters(in: .whitespaces) == link }) { return }
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.insert(link, at: end)
            if end == start + 1 { lines.insert("", at: end) }
            if end == lines.count - 1 { lines.append("") }
            try lines.joined(separator: "\n").write(to: from.url, atomically: true, encoding: .utf8)
        } else {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            try (trimmed + "\n\n## Related\n\n" + link + "\n").write(to: from.url, atomically: true, encoding: .utf8)
        }
    }

    public func delete(_ ref: NoteRef) throws {
        guard FileManager.default.fileExists(atPath: ref.url.path) else { return }
        try FileManager.default.removeItem(at: ref.url)
    }

    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        var pendingHyphen = false
        for ch in folded.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.append(ch)
            } else {
                pendingHyphen = true
            }
        }
        if out.count > 60 { out = String(out.prefix(60)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "note" : out
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }
}
