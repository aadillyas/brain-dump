import BrainDumpCore
import SwiftUI

/// The Review section: what keeps coming up, what is open, and what went quiet, one week at a time.
struct WeeklyReviewView: View {
    @Environment(AppModel.self) private var model
    /// Weeks back from this one: 0 is this week.
    @State private var weeksBack = 0
    @State private var digest: ReviewDigest?

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    private var weekStart: Date {
        let c = calendar
        let start = c.dateInterval(of: .weekOfYear, for: Date())?.start ?? c.startOfDay(for: Date())
        return c.date(byAdding: .weekOfYear, value: -weeksBack, to: start) ?? start
    }

    private var weekEnd: Date { calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? weekStart }

    private var phaseKey: Int {
        switch model.phase {
        case .home: return 0
        case .canvas: return 1
        case .processing: return 2
        case .failed: return 3
        case .review: return 4
        case .summary: return 5
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let digest {
                    ReviewContent(digest: digest, thisWeek: weeksBack == 0) { model.openNote($0) }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .task(id: "\(weeksBack)-\(phaseKey)") { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review").font(.system(size: 24, design: .serif))
                Spacer()
                HStack(spacing: 4) {
                    Button { weeksBack += 1 } label: { Image(systemName: "chevron.left") }
                        .help("Previous week")
                    Text(weeksBack == 0 ? "This week" : weeksBack == 1 ? "Last week" : "\(weeksBack) weeks ago")
                        .font(.system(size: 13)).frame(minWidth: 90)
                    Button { weeksBack = max(0, weeksBack - 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(weeksBack == 0).help("Next week")
                }
                .buttonStyle(.borderless)
            }
            Text(Self.rangeLabel(from: weekStart, to: weekEnd, calendar: calendar))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    static func rangeLabel(from: Date, to: Date, calendar: Calendar) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: to) ?? to
        let f = DateFormatter()
        f.calendar = calendar
        f.dateFormat = calendar.isDate(from, equalTo: last, toGranularity: .month) ? "d" : "d MMM"
        let end = DateFormatter()
        end.calendar = calendar
        end.dateFormat = "d MMM yyyy"
        return "\(f.string(from: from)) – \(end.string(from: last))"
    }

    private func reload() async {
        let root = Prefs.notesRoot, from = weekStart, to = weekEnd, cal = calendar
        let result = await Task.detached(priority: .userInitiated) {
            ReviewDigest.build(root: root, from: from, to: to, calendar: cal)
        }.value
        guard !Task.isCancelled else { return }
        digest = result
    }
}

/// The digest laid out as a page; separate from the scrolling shell so it can be rendered off-screen.
struct ReviewContent: View {
    let digest: ReviewDigest
    let thisWeek: Bool
    var open: (URL) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            stats
            if digest.dumps == 0 {
                Text(thisWeek ? "No dumps this week yet. Your review fills in as you talk." : "No dumps this week.")
                    .font(Theme.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
            }
            if !digest.topics.isEmpty { onYourMind }
            if !digest.actions.isEmpty { actions }
            if !digest.quiet.isEmpty { quiet }
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            stat(digest.dumps, digest.dumps == 1 ? "dump" : "dumps")
            stat(digest.words, "words")
            stat(digest.daysJournaled, digest.daysJournaled == 1 ? "day journaled" : "days journaled")
            stat(digest.streak, "day streak")
        }
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n.formatted()).font(.system(size: 28, design: .serif))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
    }

    private func heading(_ s: String, _ help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s).font(.system(size: 20, design: .serif))
            if let help { Text(help).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }

    private var onYourMind: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("On your mind", "Topics you came back to.")
            ForEach(digest.topics) { topic in
                Button { open(topic.url) } label: { card(topic) }.buttonStyle(.plain)
            }
        }
    }

    private func card(_ t: ReviewDigest.Topic) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(t.title).font(.system(size: 17, weight: .medium, design: .serif))
                if t.isNew {
                    Text("new").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                Spacer()
                Text(t.entriesInPeriod == 1 ? "once \(thisWeek ? "this week" : "that week")" : "\(t.entriesInPeriod) times \(thisWeek ? "this week" : "that week")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(t.quotes.prefix(2)) { q in
                Text("“\(q.text)”")
                    .font(.system(size: 15, design: .serif).italic())
                    .foregroundStyle(.primary.opacity(0.8)).lineLimit(3).lineSpacing(3)
            }
            if !t.openTasks.isEmpty {
                Label(t.openTasks.count == 1 ? "1 open task" : "\(t.openTasks.count) open tasks", systemImage: "circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .contentShape(Rectangle())
    }

    private var actions: some View {
        let days = Dictionary(grouping: digest.actions, by: \.day).sorted { $0.key > $1.key }
        return VStack(alignment: .leading, spacing: 14) {
            heading("Actions you captured")
            ForEach(days, id: \.key) { day, items in
                VStack(alignment: .leading, spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(items) { a in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(a.kind).font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(a.text).font(.system(size: 14))
                        }
                    }
                }
            }
        }
    }

    private var quiet: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Gone quiet", "Mentioned before, not this week.")
            ForEach(digest.quiet) { q in
                Button { open(q.url) } label: {
                    HStack {
                        Text(q.title).font(.system(size: 14))
                        Spacer()
                        Text("\(q.totalMentions) mentions · last \(q.lastMentioned.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
