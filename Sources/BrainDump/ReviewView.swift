import AppKit
import BrainDumpCore
import SwiftUI

extension ItemKind {
    /// The three kinds the user sees: task and reminder are both a To-do.
    static let displayCases: [ItemKind] = [.task, .idea, .thought]

    var color: Color {
        switch self {
        case .task, .reminder: return .blue
        case .idea: return .orange
        case .thought: return .purple
        }
    }

    var symbol: String {
        switch self {
        case .task, .reminder: return "checkmark.circle"
        case .idea: return "lightbulb"
        case .thought: return "bubble.left"
        }
    }
}

/// Transcript on the left, item cards on the right. Used while extraction runs and during review.
struct SplitReviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            TranscriptPane()
            Divider()
            Sidebar()
                .frame(width: 340)
        }
    }
}

struct TextSelection: Equatable {
    var text: String
    var range: NSRange
}

struct TranscriptPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: TextSelection?

    var body: some View {
        let dump = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        TranscriptTextView(text: dump, highlights: highlights(), color: highlightColor, selection: $selection)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if model.phase == .review, let sel = selection { addBar(sel) }
            }
            .animation(.easeOut(duration: 0.15), value: selection)
    }

    private func addBar(_ sel: TextSelection) -> some View {
        HStack(spacing: 6) {
            Text("Add as").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(ItemKind.displayCases, id: \.self) { kind in
                Button {
                    model.addManual(kind: kind, selection: sel.text, range: sel.range)
                    selection = nil
                } label: {
                    Label(kind.label, systemImage: kind.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(kind.color)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(kind.color.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var highlightColor: NSColor {
        guard let id = model.focusedItem, let entry = model.review.first(where: { $0.id == id }) else { return .clear }
        return NSColor(entry.item.kind.color).withAlphaComponent(0.25)
    }

    private func highlights() -> [NSRange] {
        guard let id = model.focusedItem, let entry = model.review.first(where: { $0.id == id }) else { return [] }
        let wanted = Set(entry.item.sentenceIndices)
        return model.sentenceRanges().filter { wanted.contains($0.index) }.map(\.range)
    }
}

/// Selectable transcript. An NSTextView exposes the selected range, which SwiftUI's Text cannot.
struct TranscriptTextView: NSViewRepresentable {
    let text: String
    let highlights: [NSRange]
    let color: NSColor
    @Binding var selection: TextSelection?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 30, height: 40)
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        guard let storage = tv.textStorage else { return }
        if storage.string != text {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = Theme.lineSpacing
            let base = NSFont.systemFont(ofSize: 19)
            let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 19) } ?? base
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para,
            ]))
        }
        // Only touch the background colour so a live selection survives hover highlights.
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        for r in highlights where NSMaxRange(r) <= storage.length {
            storage.addAttribute(.backgroundColor, value: color, range: r)
        }
        storage.endEditing()
        if selection == nil, tv.selectedRange().length > 0 {
            context.coordinator.clearing = true
            tv.setSelectedRange(NSRange(location: tv.selectedRange().location, length: 0))
            context.coordinator.clearing = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptTextView
        weak var textView: NSTextView?
        var clearing = false

        init(_ parent: TranscriptTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !clearing, let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            let next: TextSelection?
            if range.length > 0, NSMaxRange(range) <= (tv.string as NSString).length {
                let t = (tv.string as NSString).substring(with: range)
                next = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : TextSelection(text: t, range: range)
            } else {
                next = nil
            }
            DispatchQueue.main.async { [parent] in
                if parent.selection != next { parent.selection = next }
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            if model.review.isEmpty && model.phase == .review {
                VStack(spacing: 16) {
                    Spacer()
                    Text("Nothing to action. Your journal is saved.")
                        .font(.system(size: 16, design: .serif))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Open journal", action: model.openJournal)
                        Button("Done", action: model.goHome).keyboardShortcut(.defaultAction)
                    }
                    Spacer()
                }
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach($model.review) { $entry in
                            ReviewCard(entry: $entry)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(14)
                }
                if model.phase == .review { footer }
            }
        }
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if case .processing(let status) = model.phase {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
            } else {
                Text("\(model.review.count) item\(model.review.count == 1 ? "" : "s") found")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        let n = model.review.filter { $0.selected && model.destination(for: $0.item) != nil }.count
        return VStack(spacing: 8) {
            Button("Apply all approved (\(n))", action: model.apply)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(n == 0)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Button("Skip all", action: model.skipAll).buttonStyle(.link).font(.system(size: 12))
        }
        .padding(14)
    }
}

struct KindBadge: View {
    let kind: ItemKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(kind.color)
    }
}

struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    @Binding var entry: ReviewEntry
    @State private var showDate = false

    var body: some View {
        let focused = model.focusedItem == entry.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                kindMenu
                if entry.item.lowConfidence {
                    Text("unsure")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button { entry.selected = false } label: {
                    Image(systemName: "xmark.circle\(entry.selected ? "" : ".fill")")
                }
                .help("Dismiss")
                .foregroundStyle(entry.selected ? Color.secondary : Color.red)
                Button { entry.selected = true } label: {
                    Image(systemName: "checkmark.circle\(entry.selected ? ".fill" : "")")
                }
                .help("Approve")
                .foregroundStyle(entry.selected ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .font(.system(size: 17))
            .imageScale(.medium)
            .disabled(model.phase != .review)
            TextField("Title", text: $entry.item.title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
            if entry.item.kind.isActionable { dueChip } else { relatedChips }
            destinationChip
        }
        .padding(12)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? entry.item.kind.color.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 1))
        .opacity(entry.selected ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover { model.focusedItem = $0 ? entry.id : (model.focusedItem == entry.id ? nil : model.focusedItem) }
        .onTapGesture { model.focusedItem = entry.id }
    }

    private var relatedChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.related[entry.id] ?? []) { choice in
                HStack(spacing: 6) {
                    Button { model.toggleRelated(item: entry.id, note: choice.note.url) } label: {
                        Image(systemName: choice.approved ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(choice.approved ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(choice.approved ? "Linking both notes" : "Link both notes")
                    .disabled(model.phase != .review)
                    Button { model.openNote(choice.note.url) } label: {
                        Text("Related to: \(choice.note.title)").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open note")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationChip: some View {
        Group {
            if let d = model.destination(for: entry.item) {
                Label("\(d.text)", systemImage: d.icon)
            } else {
                Label("No destination", systemImage: "nosign")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .help("Where this will go")
    }

    private var kindMenu: some View {
        Menu {
            ForEach(ItemKind.displayCases, id: \.self) { kind in
                Button {
                    if entry.item.kind.label != kind.label {
                        entry.item.kind = kind
                        model.scanRelated(for: entry.item)
                    }
                } label: {
                    Label(kind.label, systemImage: kind.symbol)
                }
            }
        } label: {
            KindBadge(kind: entry.item.kind)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var dueChip: some View {
        Button { showDate = true } label: {
            Label(DueFormat.text(entry.item), systemImage: "calendar")
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDate) { DuePopover(item: $entry.item) }
    }
}

struct DuePopover: View {
    @Binding var item: ExtractedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("", selection: dateBinding, displayedComponents: item.dueHasTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            Toggle("All day", isOn: Binding(get: { !item.dueHasTime }, set: { item.dueHasTime = !$0 }))
            Button("No date") { item.due = nil; item.dueHasTime = false }
                .disabled(item.due == nil)
        }
        .padding(16)
        .frame(width: 260)
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { item.due ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() },
                set: { item.due = $0 })
    }
}

enum DueFormat {
    static func text(_ item: ExtractedItem) -> String {
        guard let due = item.due else { return "No date" }
        let cal = Calendar.current
        let day: String
        if cal.isDateInToday(due) { day = "Today" }
        else if cal.isDateInTomorrow(due) { day = "Tomorrow" }
        else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: due)).day, (2..<7).contains(days) {
            day = due.formatted(.dateTime.weekday(.wide))
        } else { day = due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return item.dueHasTime ? "\(day), \(due.formatted(date: .omitted, time: .shortened))" : day
    }
}
