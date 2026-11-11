import AppKit
import BrainDumpCore
import SwiftUI

extension ItemKind {
    /// Enabled categories, in the user's order: what the review menus offer.
    static var displayCases: [ItemKind] { ItemCategory.defaults.enabled.map(\.kind) }

    var category: ItemCategory? { ItemCategory.defaults.category(for: self) }
    var label: String { category?.name ?? rawValue.capitalized }
    var symbol: String { category?.symbol ?? "tag" }
    var isActionable: Bool { category?.isActionable ?? false }

    var color: Color {
        switch self {
        case .todo: return .blue
        case .event: return .red
        case .note: return .orange
        default:
            let palette: [Color] = [.teal, .green, .pink, .indigo, .brown, .mint]
            return palette[abs(rawValue.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % palette.count]
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
                    // A plain VStack: LazyVStack sometimes skipped drawing cards inserted with a transition
                    // until something else changed the layout, so found items looked missing.
                    VStack(spacing: 10) {
                        ForEach($model.review) { $entry in
                            ReviewCard(entry: $entry)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        if model.review.isEmpty, case .processing = model.phase {
                            RotatingQuote().padding(.top, 40).padding(.horizontal, 6)
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
        let pending = model.review.filter { $0.isAction && $0.status == .pending && model.destination(for: $0.item) != nil }.count
        return VStack(spacing: 8) {
            if pending > 0 {
                Button("Add all \(pending) remaining", action: model.approveAll)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            if pending > 0 {
                Button("Finish without the rest", action: model.finish).buttonStyle(.link).font(.system(size: 12))
            } else {
                Button("Done", action: model.finish)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
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

    private var done: Bool { entry.status == .done }
    private var dismissed: Bool { entry.status == .dismissed }
    private var working: Bool { entry.status == .working }
    /// Actions can still be edited before ✓; notes can always be retitled until review ends.
    private var editable: Bool { model.phase == .review && (entry.status == .pending || !entry.isAction) }

    var body: some View {
        let focused = model.focusedItem == entry.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                kindMenu
                if entry.item.lowConfidence && !done {
                    Text("unsure")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                controls
            }
            .buttonStyle(.plain)
            .font(.system(size: 17))
            .imageScale(.medium)
            .disabled(model.phase != .review)
            TextField("Title", text: $entry.item.title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .disabled(!editable || (entry.isAction && entry.status != .pending))
            if entry.isAction { dueChip.disabled(entry.status != .pending) }
            statusLine
        }
        .padding(12)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            done ? Color.green.opacity(0.45) : (focused ? entry.item.kind.color.opacity(0.7) : Color.primary.opacity(0.08)),
            lineWidth: focused || done ? 1.5 : 1))
        .opacity(dismissed ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { model.focusedItem = $0 ? entry.id : (model.focusedItem == entry.id ? nil : model.focusedItem) }
        .onTapGesture { model.focusedItem = entry.id }
    }

    /// ✕ and ✓ act immediately: ✓ creates the reminder or event, ✕ undoes whatever was done.
    @ViewBuilder private var controls: some View {
        if working {
            ProgressView().controlSize(.small)
        } else if dismissed {
            Button("Restore") { Task { await model.restore(entry.id) } }
                .font(.system(size: 12)).buttonStyle(.link)
        } else {
            Button { Task { await model.dismiss(entry.id) } } label: { Image(systemName: "xmark.circle") }
                .help(done ? "Undo and dismiss" : "Dismiss")
                .foregroundStyle(.secondary)
            if entry.isAction {
                Button { Task { await model.approve(entry.id) } } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(done ? "Added" : "Add now")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .disabled(done)
            } else if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Saved")
            }
        }
    }

    /// What happened or will happen: "Added to Reminders", "Saved to: Brain Dump app", an error.
    @ViewBuilder private var statusLine: some View {
        Group {
            switch entry.status {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .working:
                Label(entry.isAction ? "Adding…" : "Finding where this belongs…", systemImage: "ellipsis")
            case .dismissed:
                Label("Dismissed", systemImage: "nosign")
            case .done where !entry.isAction:
                noteDestination
            case .done:
                Label(entry.result?.summary ?? "Added", systemImage: "checkmark")
                if let topic = entry.topic { Label("Listed in: \(topic.title)", systemImage: "note.text") }
            case .pending:
                if let d = model.destination(for: entry.item) { Label(d.text, systemImage: d.icon) } else {
                    Label("No destination", systemImage: "nosign")
                }
                if let topic = entry.topic { Label("Will be listed in: \(topic.title)", systemImage: "note.text") }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    /// "Saved to: <topic>" with a menu to open it, move it to another topic, or make it a topic of its own.
    private var noteDestination: some View {
        let url = entry.result?.openURL
        let title = entry.topic?.title ?? url.map { ($0.deletingPathExtension().lastPathComponent) } ?? "a new note"
        return Menu {
            if let url { Button("Open note") { model.openNote(url) } }
            Divider()
            if entry.topic != nil { Button("Make it a new note") { Task { await model.move(entry.id, to: nil) } } }
            Menu("Move to") {
                ForEach(model.topics().filter { $0.url != url }.prefix(30), id: \.url) { topic in
                    Button(topic.title) { Task { await model.move(entry.id, to: topic) } }
                }
            }
        } label: {
            Label(entry.topic == nil ? "Saved as a new note" : "Saved to: \(title)", systemImage: "note.text")
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(entry.topic?.reason ?? "Saved as its own note")
    }

    private var kindMenu: some View {
        Menu {
            ForEach(ItemKind.displayCases, id: \.self) { kind in
                Button { Task { await model.changeKind(entry.id, to: kind) } } label: {
                    Label(kind.label, systemImage: kind.symbol)
                }
            }
        } label: {
            KindBadge(kind: entry.item.kind)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!editable)
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
