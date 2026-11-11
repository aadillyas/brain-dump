import AppKit
import BrainDumpCore
import SwiftUI

struct LibraryNote: Identifiable, Hashable {
    let url: URL
    let title: String
    let date: Date
    var id: URL { url }
}

enum LibraryFolder: String, CaseIterable {
    case journal = "Journal", ideas = "Ideas", thoughts = "Thoughts"

    var symbol: String {
        switch self {
        case .journal: return "book"
        case .ideas: return ItemKind.idea.symbol
        case .thoughts: return ItemKind.thought.symbol
        }
    }

    var color: Color {
        switch self {
        case .journal: return .secondary
        case .ideas: return ItemKind.idea.color
        case .thoughts: return ItemKind.thought.color
        }
    }

    func notes(in root: URL) -> [LibraryNote] {
        let dir = root.appendingPathComponent(rawValue, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }.map { url in
            let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let name = url.deletingPathExtension().lastPathComponent
            return LibraryNote(url: url, title: name, date: v?.creationDate ?? v?.contentModificationDate ?? .distantPast)
        }
        .sorted { self == .journal ? $0.title > $1.title : $0.date > $1.date }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [(LibraryFolder, [LibraryNote])] = []
    private var root: URL { Prefs.notesRoot }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.system(size: 17, design: .serif))
                Spacer()
                Text(root.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.librarySelection ?? root]) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 240)
                Divider()
                if let url = model.librarySelection {
                    NoteViewer(url: url, root: root).id(url)
                } else {
                    Text("Choose a note").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.paper)
        .onAppear(perform: reload)
    }

    private var list: some View {
        @Bindable var model = model
        return List(selection: $model.librarySelection) {
            ForEach(groups, id: \.0) { folder, notes in
                Section {
                    ForEach(notes) { note in
                        Text(note.title).lineLimit(1).tag(note.url)
                    }
                    if notes.isEmpty { Text("Nothing yet").foregroundStyle(.tertiary) }
                } header: {
                    Label(folder.rawValue, systemImage: folder.symbol).foregroundStyle(folder.color)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func reload() {
        groups = LibraryFolder.allCases.map { ($0, $0.notes(in: root)) }
    }
}

struct NoteViewer: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let root: URL
    @State private var meta: [String] = []
    @State private var blocks: [MarkdownBlock] = []
    @State private var missing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if missing {
                    Text("This note no longer exists.").foregroundStyle(.secondary)
                }
                if !meta.isEmpty {
                    Text(meta.joined(separator: "  ·  "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(blocks) { block in blockView(block) }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .environment(\.openURL, OpenURLAction { link in
            guard link.scheme == "bdnote", let target = Self.resolve(String(link.absoluteString.dropFirst("bdnote:".count)).removingPercentEncoding ?? "", root: root) else {
                return .systemAction
            }
            model.librarySelection = target
            return .handled
        })
        .onAppear(perform: load)
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.attributed)
                .font(.system(size: level == 1 ? 26 : level == 2 ? 21 : 17, weight: .semibold, design: .serif))
                .padding(.top, level == 1 ? 0 : 6)
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary)
                Text(block.attributed).font(Theme.body).lineSpacing(5)
            }
        case .quote:
            Text(block.attributed).font(Theme.body.italic()).foregroundStyle(.secondary).lineSpacing(5)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 2) }
        case .paragraph:
            Text(block.attributed).font(Theme.body).lineSpacing(5)
        }
    }

    private func load() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { missing = true; return }
        let (front, body) = Markdown.splitFrontmatter(raw)
        meta = front
        blocks = Markdown.blocks(body) { Self.resolve($0, root: root) != nil }
    }

    /// Finds the note a wiki link points at: root-relative path first, then any note with that name.
    static func resolve(_ link: String, root: URL) -> URL? {
        let fm = FileManager.default
        let direct = root.appendingPathComponent(link + ".md")
        if fm.fileExists(atPath: direct.path) { return direct }
        for folder in LibraryFolder.allCases {
            let u = root.appendingPathComponent(folder.rawValue).appendingPathComponent(link + ".md")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

struct MarkdownBlock: Identifiable {
    enum Kind { case heading(Int), bullet(String), quote, paragraph }
    let id = UUID()
    let kind: Kind
    let attributed: AttributedString
}

enum Markdown {
    /// Returns frontmatter as small "key: value" strings, and the remaining body.
    static func splitFrontmatter(_ text: String) -> ([String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return ([], text) }
        let meta = lines[1..<end].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (meta, lines[(end + 1)...].joined(separator: "\n"))
    }

    static func blocks(_ body: String, linkExists: (String) -> Bool) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        func flush() {
            guard !para.isEmpty else { return }
            out.append(MarkdownBlock(kind: .paragraph, attributed: inline(para.joined(separator: " "), linkExists)))
            para = []
        }
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix(while: { $0 == "#" }).count
            let afterHashes = line.dropFirst(hashes)
            let digits = line.prefix(while: \.isNumber)
            let afterDigits = line.dropFirst(digits.count)
            if (1...6).contains(hashes), afterHashes.first == " " {
                flush()
                out.append(MarkdownBlock(kind: .heading(hashes), attributed: inline(afterHashes.trimmingCharacters(in: .whitespaces), linkExists)))
            } else if let f = line.first, "-*+".contains(f), line.dropFirst().first == " " {
                flush()
                out.append(MarkdownBlock(kind: .bullet("•"), attributed: inline(line.dropFirst(2).trimmingCharacters(in: .whitespaces), linkExists)))
            } else if !digits.isEmpty, let p = afterDigits.first, p == "." || p == ")", afterDigits.dropFirst().first == " " {
                flush()
                out.append(MarkdownBlock(kind: .bullet("\(digits)."), attributed: inline(afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces), linkExists)))
            } else if line.hasPrefix(">") {
                flush()
                out.append(MarkdownBlock(kind: .quote, attributed: inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces), linkExists)))
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    /// Bold, italic, code and links via AttributedString; `[[wiki]]` links become bdnote: links when the file exists.
    static func inline(_ text: String, _ linkExists: (String) -> Bool) -> AttributedString {
        var s = text
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        if let re = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) {
            let ns = s as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                last = m.range.location + m.range.length
                let target = ns.substring(with: m.range(at: 1))
                let label = m.range(at: 2).location == NSNotFound ? target : ns.substring(with: m.range(at: 2))
                if linkExists(target) {
                    result += "[\(label)](bdnote:\(target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target))"
                } else {
                    result += label
                }
            }
            s = result + ns.substring(from: last)
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
