import AppKit
import SwiftUI

struct JournalDay: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date
    let entries: Int
    var id: URL { url }

    static let titleFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"; return f
    }()
    var title: String { Self.titleFormat.string(from: date) }

    static func load(root: URL) -> [JournalDay] {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        return NoteFiles.markdownFiles(in: "Journal", root: root).compactMap { url in
            guard let date = parse.date(from: url.deletingPathExtension().lastPathComponent) else { return nil }
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let count = raw.components(separatedBy: "\n").filter { $0.range(of: #"^## \d{1,2}:\d{2}"#, options: .regularExpression) != nil }.count
            return JournalDay(url: url, date: date, entries: count)
        }
        .sorted { $0.date > $1.date }
    }
}

struct JournalView: View {
    @Environment(AppModel.self) private var model
    @State private var days: [JournalDay] = []
    @State private var loaded = false
    @State private var token = 0

    private var selection: URL? {
        guard let u = model.selectedNote, u.deletingLastPathComponent().lastPathComponent == "Journal" else { return nil }
        return u
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                Text("Journal").font(.system(size: 22, design: .serif))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                Group {
                    if days.isEmpty {
                        Text(loaded ? "No journal entries yet. Every dump is saved here, one file per day." : "")
                            .font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(24)
                            .frame(maxHeight: .infinity)
                    } else {
                        List(selection: $model.selectedNote) {
                            ForEach(days) { day in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(day.title).font(.system(size: 15, weight: .medium, design: .serif))
                                    Text(day.entries == 1 ? "1 entry" : "\(day.entries) entries")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                .tag(Optional(day.url))
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                .frame(width: 250)
                Divider()
                if let url = selection {
                    JournalDetailView(url: url).id("\(url.path)#\(token)")
                } else {
                    Text(days.isEmpty ? "" : "Choose a day").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.phase) { reload() }
    }

    private func reload() {
        let root = NoteFiles.root
        Task {
            let result = await Task.detached(priority: .userInitiated) { JournalDay.load(root: root) }.value
            days = result
            loaded = true
            token += 1
            if selection == nil, let first = result.first { model.selectedNote = first.url }
        }
    }
}

struct JournalDetailView: View {
    @Environment(AppModel.self) private var model
    let url: URL

    struct Block: Identifiable {
        let id = UUID()
        var time: String
        var paragraphs: [String] = []
        var actions: [String] = []
    }

    @State private var title = ""
    @State private var blocks: [Block] = []
    @State private var missing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if missing {
                    Text("This day no longer exists.").foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 28, weight: .semibold, design: .serif)).textSelection(.enabled)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Reveal in Finder", systemImage: "folder") }
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open in editor", systemImage: "square.and.pencil") }
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary).buttonStyle(.plain)
                    ForEach(blocks) { b in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(b.time).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                            ForEach(Array(b.paragraphs.enumerated()), id: \.offset) { _, p in
                                Text(Markdown.inline(p) { NoteFiles.resolve($0) != nil }).font(Theme.body).lineSpacing(5).textSelection(.enabled)
                            }
                            if !b.actions.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(b.actions.enumerated()), id: \.offset) { _, a in
                                        Text(a).font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 2) }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    }
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

    private func load() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { missing = true; return }
        let (_, body) = Markdown.splitFrontmatter(raw)
        title = JournalDay.titleFormat.string(from: {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: url.deletingPathExtension().lastPathComponent) ?? Date()
        }())
        var out: [Block] = []
        var inActions = false
        var para: [String] = []
        func flush() {
            if !para.isEmpty, !out.isEmpty { out[out.count - 1].paragraphs.append(para.joined(separator: " ")) }
            para = []
        }
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush(); inActions = false
                out.append(Block(time: String(line.dropFirst(3))))
            } else if line.hasPrefix("### ") {
                flush(); inActions = line.lowercased().hasPrefix("### actions")
            } else if line.hasPrefix("# ") {
                continue
            } else if inActions {
                if line.hasPrefix("- "), !out.isEmpty { out[out.count - 1].actions.append(NoteFiles.plain(String(line.dropFirst(2)))) }
            } else if line.isEmpty {
                flush()
            } else {
                para.append(line)
            }
        }
        flush()
        blocks = out
    }
}
