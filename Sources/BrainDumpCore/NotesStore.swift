import Foundation

public struct NotesStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// ~/BrainDump
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BrainDump", isDirectory: true)
    }

    /// Creates root and Journal/ if missing, and merges folders from earlier versions into Notes/.
    public func prepare() throws {
        for sub in ["", "Journal"] {
            try FileManager.default.createDirectory(
                at: sub.isEmpty ? root : root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try migrateLegacyFolders()
    }

    /// Note folders from earlier versions (one per category); every note now lives in Notes/.
    public static let legacyFolders = ["Ideas", "Reflections", "Thoughts"]

    /// Moves notes from `legacyFolders` into Notes/ (renaming on clashes), sets their `type` to note, and
    /// rewrites `[[Ideas/x]]`-style links in all notes and journal entries. Does nothing once they are gone.
    @discardableResult
    public func migrateLegacyFolders() throws -> Int {
        let fm = FileManager.default
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        var renames: [String: String] = [:]
        for folder in Self.legacyFolders {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            try fm.createDirectory(at: notes, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "md" {
                let slug = file.deletingPathExtension().lastPathComponent
                var name = slug
                var n = 2
                while fm.fileExists(atPath: notes.appendingPathComponent(name + ".md").path) {
                    name = "\(slug)-\(n)"
                    n += 1
                }
                try fm.moveItem(at: file, to: notes.appendingPathComponent(name + ".md"))
                renames["\(folder)/\(slug)"] = "Notes/\(name)"
            }
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy({ $0.hasPrefix(".") }) {
                try? fm.removeItem(at: dir)
            }
        }
        guard !renames.isEmpty else { return 0 }
        for sub in ["Notes", "Journal"] {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "md" {
                guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let original = text
                for (old, new) in renames {
                    for end in ["]]", "|", "#"] { text = text.replacingOccurrences(of: "[[\(old)\(end)", with: "[[\(new)\(end)") }
                }
                if sub == "Notes" {
                    for legacy in ["idea", "reflection", "thought"] {
                        text = text.replacingOccurrences(of: "\ntype: \(legacy)\n", with: "\ntype: note\n")
                    }
                }
                if text != original { try text.write(to: file, atomically: true, encoding: .utf8) }
            }
        }
        return renames.count
    }

    /// Writes Journal/yyyy-MM-dd.md, or appends a "## HH:mm" section if the day already has one.
    /// The returned link points at that section, e.g. "Journal/2026-11-12#08:12".
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
        return NoteRef(url: url, wikiLink: "Journal/\(day)#\(time)")
    }

    /// Creates <category folder>/<slug>.md with frontmatter and a link back to the journal.
    public func createNote(category: ItemCategory, title: String, body: String, journal: NoteRef, date: Date) throws -> NoteRef {
        try prepare()
        let folder = category.folder.isEmpty ? "Notes" : category.folder
        let type = category.id
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            updated: \(created)
            mentions: 1
            ---

            # \(heading)

            ## Log

            \(Self.logEntry(quote: body, journal: journal, date: date))
            """
        let url = dir.appendingPathComponent(name + ".md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return NoteRef(url: url, wikiLink: "\(folder)/\(name)")
    }

    /// One dated log entry: a heading linking the journal section, then the speaker's words as a quote.
    static func logEntry(quote: String, journal: NoteRef, date: Date) -> String {
        let words = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return "### \(format(date, "yyyy-MM-dd HH:mm")) · [[\(journal.wikiLink)]]\n\n\(words)\n"
    }

    /// Adds a new mention to an existing note: a log entry at the top of "## Log" (created if missing, for notes
    /// written before living notes), and bumps `updated` and `mentions`. Returns the previous content for undo.
    @discardableResult
    public func appendMention(to url: URL, quote: String, journal: NoteRef, date: Date) throws -> String {
        let old = try String(contentsOf: url, encoding: .utf8)
        var lines = old.components(separatedBy: "\n")
        let entry = Self.logEntry(quote: quote, journal: journal, date: date).components(separatedBy: "\n")

        // Frontmatter: bump mentions and updated, adding them if missing.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            let stamp = Self.isoFormatter().string(from: date)
            var mentions = 1
            if let i = lines[1..<end].firstIndex(where: { $0.hasPrefix("mentions:") }) {
                mentions = Int(lines[i].dropFirst("mentions:".count).trimmingCharacters(in: .whitespaces)) ?? 1
                lines.remove(at: i)
            }
            lines.removeAll { $0.hasPrefix("updated:") }
            let close = lines.dropFirst().firstIndex(of: "---")!
            lines.insert(contentsOf: ["updated: \(stamp)", "mentions: \(mentions + 1)"], at: close)
        }

        if let log = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Log" }) {
            lines.insert(contentsOf: [""] + entry.dropLast(), at: log + 1)
        } else {
            let related = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "## Related" } ?? lines.count
            var at = related
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(contentsOf: ["", "## Log", ""] + entry, at: at)
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return old
    }

    /// Adds `- [ ] text · [[journal]]` under "## Tasks" (created before "## Log" or "## Related" if missing)
    /// and bumps `updated`: a to-do or event that belongs to this note's subject.
    public func appendTask(to url: URL, text: String, journal: NoteRef, date: Date) throws {
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let entry = "- [ ] \(text) · [[\(journal.wikiLink)]]"
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var front = Array(lines[1..<end]).filter { !$0.hasPrefix("updated:") }
            front.append("updated: \(Self.isoFormatter().string(from: date))")
            lines.replaceSubrange(1..<end, with: front)
        }
        if let tasks = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Tasks" }) {
            var end = lines[(tasks + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
            while end > tasks + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.insert(entry, at: end)
            if end == tasks + 1 { lines.insert("", at: end) }
        } else {
            let at = lines.firstIndex { ["## Log", "## Related"].contains($0.trimmingCharacters(in: .whitespaces)) } ?? lines.count
            lines.insert(contentsOf: ["## Tasks", "", entry, ""], at: at)
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        if !text.hasSuffix("\n") { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Restores a note's content saved by `appendMention`.
    public func restore(_ url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Appends an "Actions" list to the journal entry written by `writeJournal`.
    public func appendActions(_ lines: [String], to journal: NoteRef) throws {
        guard !lines.isEmpty else { return }
        var content = try String(contentsOf: journal.url, encoding: .utf8)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        content += "\n\n### Actions\n\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try content.write(to: journal.url, atomically: true, encoding: .utf8)
    }

    /// Adds `- [[to]] — reason` under a "## Related" section of `from`, creating the section if missing.
    /// No duplicates: a note already linked to `to` is left alone.
    public func addRelatedLink(from: NoteRef, to: NoteRef, reason: String? = nil) throws {
        let target = "- [[\(to.wikiLink)]]"
        let reasonText = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let link = reasonText.isEmpty ? target : "\(target) — \(reasonText)"
        let content = try String(contentsOf: from.url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Related" }) {
            var end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.count
            if lines[(start + 1)..<end].contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(target) }) { return }
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
