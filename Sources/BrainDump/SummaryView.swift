import AppKit
import BrainDumpCore
import SwiftUI

struct SummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.results.isEmpty && model.failures.isEmpty ? "Journal saved" : "All set")
                        .font(.system(size: 24, design: .serif))
                    Text(recap)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    ForEach(model.results) { result in
                        row(result)
                    }
                    ForEach(model.failures) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(failure.title, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(failure.message).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .padding(.horizontal, 24)
            }
            HStack {
                Button("Open journal", action: model.openJournal)
                Spacer()
                Button("New dump", action: model.newDump)
                Button("Done", action: model.goHome).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }

    private var recap: String {
        var parts = ["\(model.recapWords) word\(model.recapWords == 1 ? "" : "s") in \(RecorderPanel.format(model.recapSeconds))"]
        if model.home.streak > 0 { parts.append("\(model.home.streak) day streak") }
        return parts.joined(separator: " · ")
    }

    private func row(_ result: ActionResult) -> some View {
        let undone = model.undone.contains(result.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let kind = model.kindByItem[result.id] {
                    Image(systemName: kind.symbol).foregroundStyle(kind.color)
                }
                Text(result.summary)
                    .strikethrough(undone)
                    .foregroundStyle(undone ? .secondary : .primary)
                Spacer()
                if let url = result.openURL {
                    Button { if url.pathExtension == "md" { model.openNote(url) } else { NSWorkspace.shared.open(url) } } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless)
                        .help(url.pathExtension == "md" ? "Open in Library" : "Open")
                }
                Button(undone ? "Undone" : "Undo") { model.undo(result) }
                    .disabled(undone)
            }
            if let error = model.undoErrors[result.id] {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }
}
