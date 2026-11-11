import BrainDumpCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    let ns: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(greeting).font(.system(size: 30, design: .serif))
                        Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    dumpBar
                    stats
                    if !model.home.today.isEmpty { section("Today", model.home.today, showDate: false) }
                    if !model.home.recent.isEmpty { section("Recent", model.home.recent, showDate: true) }
                    if model.home.entries.isEmpty {
                        Text("Your dumps will show up here. Say whatever is on your mind, and it gets sorted for you.")
                            .font(.system(size: 14, design: .serif))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
        .onAppear { model.loadHome() }
    }

    private var dumpBar: some View {
        Button { withAnimation(.spring(duration: 0.5, bounce: 0.15)) { model.startDump() } } label: {
            HStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Theme.accent, in: Circle())
                Text("What's on your mind?")
                    .font(.system(size: 22, design: .serif))
                    .foregroundStyle(.primary.opacity(0.75))
                Spacer()
                Text("Start a dump").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
                    .matchedGeometryEffect(id: "dumpCard", in: ns)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            stat("flame.fill", model.home.streak == 1 ? "1 day streak" : "\(model.home.streak) day streak", .orange)
            stat("square.and.pencil", todayText, Theme.accent)
        }
    }

    private var todayText: String {
        let n = model.home.today.count
        return n == 1 ? "1 dump today" : "\(n) dumps today"
    }

    private func stat(_ symbol: String, _ text: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func section(_ title: String, _ entries: [JournalEntry], showDate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(entries) { entry in
                    Button { model.openNote(entry.url) } label: { row(entry, showDate: showDate) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ entry: JournalEntry, showDate: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(showDate ? entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                          : entry.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: showDate ? 150 : 70, alignment: .leading)
            Text(entry.preview.isEmpty ? "(empty)" : entry.preview)
                .font(.system(size: 15, design: .serif))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(entry.words) words").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var subtitle: String {
        Date().formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}
