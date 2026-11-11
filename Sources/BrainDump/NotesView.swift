import AppKit
import BrainDumpCore
import SwiftUI

// MARK: Shared helpers

enum NoteFiles {
    static var root: URL { Prefs.notesRoot }

    /// Finds the note a wiki link points at: root-relative path first, then any note with that name.
    static func resolve(_ rawLink: String, root: URL = NoteFiles.root) -> URL? {
        let link = rawLink.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawLink
        let fm = FileManager.default
        let direct = root.appendingPathComponent(link + ".md")
        if fm.fileExists(atPath: direct.path) { return direct }
        for folder in ["Journal"] + ItemCategory.defaults.noteFolders {
            let u = root.appendingPathComponent(folder).appendingPathComponent(link + ".md")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func markdownFiles(in folder: String, root: URL = NoteFiles.root) -> [URL] {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func wikiLinks(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Text with `[[…]]` links and markdown decoration removed, for one-line previews.
    static func plain(_ text: String) -> String {
        var s = text
        if let re = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) {
            let ns = s as NSString
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
        }
        return s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

/// A tappable link that opens another note or journal day inside the app.
struct NoteLink: View {
    @Environment(AppModel.self) private var model
    let label: String
    let url: URL?

    var body: some View {
        if let url {
            Button { model.openNote(url) } label: {
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        } else {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Parsed note

struct ParsedNote {
    struct Task { var text: String; var done: Bool; var link: String? }
    struct LogEntry: Identifiable { let id = UUID(); var when: String; var link: String?; var quote: String }
    struct Related: Identifiable { let id = UUID(); var target: String; var reason: String? }

    var title: String
    var type: String?
    var created: Date?
    var updated: Date?
    var mentions = 1
    var intro: [String] = []
    var tasks: [Task] = []
    var log: [LogEntry] = []
    var related: [Related] = []

    init(raw: String, fallbackTitle: String) {
        let front = NoteGraph.frontmatter(raw)
        type = front["type"]
        created = front["created"].flatMap(NoteFiles.parseDate)
        updated = front["updated"].flatMap(NoteFiles.parseDate)
        mentions = max(1, Int(front["mentions"] ?? "") ?? 1)
        title = fallbackTitle
        let (_, body) = Markdown.splitFrontmatter(raw)

        var section = ""
        var entry: LogEntry?
        var para: [String] = []
        func flushPara() {
            if !para.isEmpty { intro.append(para.joined(separator: " ")); para = [] }
        }
        func flushEntry() { if let e = entry { log.append(e); entry = nil } }
        let taskRe = try? NSRegularExpression(pattern: #"^[-*]\s*\[([ xX])\]\s*(.*)$"#)
        let relRe = try? NSRegularExpression(pattern: #"^[-*]\s*\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]\s*(?:[—–-]+\s*(.*))?$"#)

        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") && section.isEmpty && title == fallbackTitle {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces); continue
            }
            if line.hasPrefix("## ") {
                flushPara(); flushEntry()
                section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            switch section {
            case "tasks":
                guard let m = taskRe?.firstMatch(in: line, range: full) else { continue }
                var text = ns.substring(with: m.range(at: 2))
                let link = NoteFiles.wikiLinks(in: text).first
                if let dot = text.range(of: " · ") { text = String(text[..<dot.lowerBound]) }
                tasks.append(Task(text: text.trimmingCharacters(in: .whitespaces), done: ns.substring(with: m.range(at: 1)) != " ", link: link))
            case "log":
                if line.hasPrefix("### ") {
                    flushEntry()
                    let head = String(line.dropFirst(4))
                    let when = head.components(separatedBy: " · ").first ?? head
                    entry = LogEntry(when: when, link: NoteFiles.wikiLinks(in: head).first, quote: "")
                } else if line.hasPrefix(">") {
                    let q = line.dropFirst().trimmingCharacters(in: .whitespaces)
                    if entry == nil { entry = LogEntry(when: "", link: nil, quote: "") }
                    let prev = entry?.quote ?? ""
                    entry?.quote = prev.isEmpty ? q : prev + "\n" + q
                }
            case "related":
                if let m = relRe?.firstMatch(in: line, range: full) {
                    let reason = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    related.append(Related(target: ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                                           reason: (reason ?? "").isEmpty ? nil : reason))
                }
            default:
                if line.isEmpty { flushPara() } else { para.append(line) }
            }
        }
        flushPara(); flushEntry()
    }
}

// MARK: Notes list

struct NoteSummary: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let mentions: Int
    let updated: Date
    let subtitle: String
    let searchText: String
    var id: URL { url }

    static func load(root: URL) -> [NoteSummary] {
        var out: [NoteSummary] = []
        for folder in ItemCategory.defaults.noteFolders {
            for url in NoteFiles.markdownFiles(in: folder, root: root) {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let slug = url.deletingPathExtension().lastPathComponent
                let note = ParsedNote(raw: raw, fallbackTitle: slug)
                let updated = note.updated ?? note.created ?? NoteFiles.modified(url) ?? .distantPast
                let quote = note.log.first?.quote.components(separatedBy: "\n").first ?? ""
                let subtitle = !quote.isEmpty ? quote : (note.intro.first ?? "")
                let parsed = RelatedNotes.parse(raw, fallback: slug)
                out.append(NoteSummary(url: url, title: note.title, mentions: note.mentions, updated: updated,
                                       subtitle: NoteFiles.plain(subtitle), searchText: (parsed.title + "\n" + parsed.body).lowercased()))
            }
        }
        return out.sorted { $0.updated > $1.updated }
    }
}

struct NotesView: View {
    @Environment(AppModel.self) private var model
    @State private var notes: [NoteSummary] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var token = 0

    private var filtered: [NoteSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.searchText.contains(q) }
    }

    private var selection: URL? {
        guard let u = model.selectedNote, u.deletingLastPathComponent().lastPathComponent != "Journal" else { return nil }
        return u
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            if model.notesShowGraph {
                GraphView()
            } else {
                HStack(spacing: 0) {
                    listColumn.frame(width: 310)
                    Divider()
                    detail
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.phase) { reload() }
    }

    private var header: some View {
        @Bindable var model = model
        return HStack {
            Text("Notes").font(.system(size: 22, design: .serif))
            Spacer()
            Picker("View", selection: $model.notesShowGraph) {
                Label("List", systemImage: "list.bullet").tag(false)
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            if notes.isEmpty {
                Spacer()
                if loaded {
                    Text("No notes yet. Ideas and reflections from your dumps are filed here as living notes.")
                        .font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(24)
                }
                Spacer()
            } else if filtered.isEmpty {
                Text("No matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(24)
                Spacer()
            } else {
                @Bindable var model = model
                List(selection: $model.selectedNote) {
                    ForEach(filtered) { note in row(note).tag(Optional(note.url)) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ note: NoteSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title).font(.system(size: 15, weight: .medium, design: .serif)).lineLimit(1)
            HStack(spacing: 4) {
                Text(note.mentions == 1 ? "1 mention" : "\(note.mentions) mentions")
                Text("·")
                Text(note.updated.formatted(.relative(presentation: .named)))
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            if !note.subtitle.isEmpty {
                Text(note.subtitle).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var detail: some View {
        if let url = selection {
            NoteDetailView(url: url).id("\(url.path)#\(token)")
        } else {
            Text(notes.isEmpty ? "" : "Choose a note").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() {
        let root = NoteFiles.root
        Task {
            let result = await Task.detached(priority: .userInitiated) { NoteSummary.load(root: root) }.value
            notes = result
            loaded = true
            token += 1
            if selection == nil, let first = result.first {
                model.selectedNote = first.url
            }
        }
    }
}

// MARK: Note detail

struct NoteDetailView: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var note: ParsedNote?
    @State private var missing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if missing {
                    Text("This note no longer exists.").foregroundStyle(.secondary)
                } else if let note {
                    content(note)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(32)
        }

        .environment(\.openURL, OpenURLAction { link in
            guard link.scheme == "bdnote",
                  let target = NoteFiles.resolve(String(link.absoluteString.dropFirst("bdnote:".count)).removingPercentEncoding ?? "")
            else { return .systemAction }
            model.openNote(target)
            return .handled
        })
        .onAppear(perform: load)
    }

    @ViewBuilder private func content(_ note: ParsedNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title).font(.system(size: 28, weight: .semibold, design: .serif)).textSelection(.enabled)
            HStack(spacing: 6) {
                Text(note.mentions == 1 ? "1 mention" : "\(note.mentions) mentions")
                if let d = note.updated ?? note.created { Text("·"); Text("updated " + d.formatted(.relative(presentation: .named))) }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Reveal in Finder", systemImage: "folder").fixedSize() }
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in editor", systemImage: "square.and.pencil").fixedSize() }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .buttonStyle(.plain).lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }

        ForEach(Array(note.intro.enumerated()), id: \.offset) { _, p in
            Text(Markdown.inline(p) { NoteFiles.resolve($0) != nil }).font(Theme.body).lineSpacing(5)
        }

        if !note.tasks.isEmpty {
            sectionTitle("Tasks")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(note.tasks.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: t.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(t.done ? Theme.accent : .secondary)
                        Text(t.text).font(Theme.body).strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                        if let link = t.link { NoteLink(label: Self.linkLabel(link), url: NoteFiles.resolve(link)) }
                    }
                }
            }
        }

        if !note.log.isEmpty {
            sectionTitle("Log")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(note.log) { e in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(Self.prettyWhen(e.when)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            if let l = e.link { NoteLink(label: "Journal", url: NoteFiles.resolve(l)) }
                        }
                        Text(Markdown.inline(e.quote) { NoteFiles.resolve($0) != nil })
                            .font(Theme.body.italic()).foregroundStyle(.primary.opacity(0.85)).lineSpacing(5)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2) }
                            .textSelection(.enabled)
                    }
                }
            }
        }

        if !note.related.isEmpty {
            sectionTitle("Related")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(note.related) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        NoteLink(label: Self.linkLabel(r.target), url: NoteFiles.resolve(r.target))
                        if let reason = r.reason { Text("· " + reason).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 19, weight: .semibold, design: .serif)).padding(.top, 8)
    }

    static func linkLabel(_ target: String) -> String {
        let base = target.split(separator: "#").first.map(String.init) ?? target
        let name = base.split(separator: "/").last.map(String.init) ?? base
        if base.hasPrefix("Journal/") {
            let pretty = prettyWhen(name)
            if pretty != name { return pretty }
        }
        return name.replacingOccurrences(of: "-", with: " ").capitalizedFirst
    }

    /// "2026-11-12 08:12" → "Thu 12 Nov · 08:12".
    static func prettyWhen(_ s: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) {
                let out = DateFormatter()
                out.dateFormat = fmt.contains("HH") ? "EEE d MMM · HH:mm" : "EEE d MMM"
                return out.string(from: d)
            }
        }
        return s
    }

    private func load() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { missing = true; return }
        note = ParsedNote(raw: raw, fallbackTitle: url.deletingPathExtension().lastPathComponent)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
