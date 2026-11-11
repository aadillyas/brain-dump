import AppKit
import BrainDumpCore
import BrainDumpLLM
import Observation
import SwiftUI

enum Phase: Equatable {
    case home
    case canvas
    case processing(String)
    case failed(String)
    case review
    case summary
}

struct ReviewEntry: Identifiable {
    enum Status: Equatable {
        /// An action waiting for ✓ or ✕.
        case pending
        /// Being created, or a note being filed.
        case working
        case done
        case dismissed
        case failed(String)
    }

    var item: ExtractedItem
    var status = Status.pending
    /// What applying did: for undo, moving a note and the summary.
    var result: ActionResult?
    /// Notes: the topic it was filed under (nil after filing means a new topic). Actions: the topic note
    /// the to-do is listed in when approved.
    var topic: TopicMatch?
    var id: UUID { item.id }
    var isAction: Bool { item.kind.isActionable }
}

extension ReviewEntry.Status {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

/// Main window sections.
enum AppSection: Hashable {
    case dump, review, notes, journal
}

struct HomeData {
    var entries: [JournalEntry] = []
    var streak = 0
    var today: [JournalEntry] = []
    var recent: [JournalEntry] = []
}

struct Failure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor @Observable
final class AppModel {
    let dictation = Dictation()

    var phase = Phase.home
    var text = ""
    var timerSeconds = Prefs.timerSeconds
    /// Seconds spent on this dump; keeps counting past the target.
    var elapsed = 0
    var timerRunning = false
    var review: [ReviewEntry] = []
    /// Everything applied in this dump, for the summary screen and its undo buttons.
    var results: [ActionResult] = []
    var failures: [Failure] = []
    var undone: Set<UUID> = []
    var undoErrors: [UUID: String] = [:]
    var sentences: [Sentence] = []
    /// The card being hovered or selected; its quote is highlighted in the transcript.
    var focusedItem: UUID?
    var kindByItem: [UUID: ItemKind] = [:]
    var showIntro = !Prefs.introSeen
    var section = AppSection.dump
    /// The note or journal entry open in the Notes or Journal section.
    var selectedNote: URL?
    /// Notes section shows the graph instead of a note.
    var notesShowGraph = false
    var home = HomeData()
    /// Recap of the dump just finished, for the summary screen.
    var recapWords = 0
    var recapSeconds = 0

    var remaining: Int { max(0, timerSeconds - elapsed) }
    var overtime: Int { timerSeconds > 0 ? max(0, elapsed - timerSeconds) : 0 }
    var isOvertime: Bool { timerSeconds > 0 && elapsed > timerSeconds }

    @ObservationIgnored private var recordingBase = ""
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var store: NotesStore?
    @ObservationIgnored private var journal: NoteRef?
    /// The model that read the dump, kept loaded to file notes into topics during review.
    @ObservationIgnored private var matchProvider: Provider?
    @ObservationIgnored private var matcher: (any TopicMatcher)?
    @ObservationIgnored private var matchTask: Task<Void, Never>?

    var isDictating: Bool { dictation.state == .recording || dictation.state == .finishing }
    var journalURL: URL? { journal?.url }

    var displayText: String { isDictating ? Self.join(recordingBase, dictation.confirmed) : text }

    var wordCount: Int {
        let full = isDictating ? Self.join(displayText, dictation.volatile) : text
        return full.split(whereSeparator: \.isWhitespace).count
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a.last?.isWhitespace == true ? a + b : a + " " + b
    }

    // MARK: Canvas

    func toggleRecording() {
        Task {
            if dictation.isRecording { await stopRecording() } else { await startRecording() }
        }
    }

    private func startRecording() async {
        guard dictation.state == .idle else { return }
        recordingBase = text
        await dictation.start()
        if dictation.isRecording { startTimer() }
    }

    private func stopRecording() async {
        let spoken = await dictation.stop()
        text = Self.join(recordingBase, spoken)
    }

    func typed() { if !timerRunning && elapsed == 0 { startTimer() } }

    func startTimer() {
        guard !timerRunning else { return }
        timerRunning = true
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                elapsed += 1
            }
        }
    }

    func pauseTimer() {
        timerRunning = false
        tickTask?.cancel()
    }

    func toggleTimer() { timerRunning ? pauseTimer() : startTimer() }

    func resetTimer() {
        pauseTimer()
        elapsed = 0
    }

    func setTimer(_ seconds: Int) {
        timerSeconds = seconds
        Prefs.timerSeconds = seconds
    }

    func newDump() {
        matchTask?.cancel()
        matchTask = nil
        let previous = matchProvider
        matchProvider = nil
        matcher = nil
        Task { await previous?.local?.unload() }
        text = ""
        review = []
        sentences = []
        focusedItem = nil
        kindByItem = [:]
        results = []
        failures = []
        undone = []
        undoErrors = [:]
        journal = nil
        store = nil
        resetTimer()
        phase = .canvas
    }

    /// Back to the home screen, discarding any unsent state.
    func goHome() {
        newDump()
        phase = .home
        loadHome()
    }

    /// Home bar clicked: open a fresh dump and start recording.
    func startDump() {
        newDump()
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if phase == .canvas { toggleRecording() }
        }
    }

    func loadHome() {
        let root = Prefs.notesRoot
        Task {
            let entries = await Task.detached(priority: .utility) { JournalIndex.load(root: root) }.value
            let cal = Calendar.current
            home = HomeData(
                entries: entries, streak: JournalIndex.streak(entries),
                today: entries.filter { cal.isDateInToday($0.date) },
                recent: Array(entries.filter { !cal.isDateInToday($0.date) }.prefix(8)))
        }
    }

    // MARK: Processing

    func done() {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || isDictating else { return }
        Task { await process() }
    }

    func retry() { Task { await process() } }

    func skipToJournal() {
        review = []
        finishToSummary()
    }

    private func process() async {
        pauseTimer()
        phase = .processing("Saving your journal…")
        if dictation.isRecording { await stopRecording() }
        dictation.releaseModels()
        let dump = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dump.isEmpty else { phase = .canvas; return }
        recapWords = dump.split(whereSeparator: \.isWhitespace).count
        recapSeconds = elapsed
        sentences = Segmenter.sentences(in: dump)

        if journal == nil {
            do {
                let store = NotesStore(root: Prefs.notesRoot)
                try store.prepare()
                journal = try store.writeJournal(text: dump, date: Date())
                self.store = store
            } catch {
                phase = .failed("Could not save your journal: \(error.localizedDescription)")
                return
            }
        }

        var local: LocalLLM?
        await endMatching()
        do {
            let provider = try await Pipeline.provider(cloud: Prefs.useCloud, apple: Prefs.useApple, local: Prefs.localModel) { [weak self] status in
                Task { @MainActor in self?.showProgress(status) }
            }
            local = provider.local
            phase = .processing("Reading your dump…")
            var extractor = Extractor(provider: provider.llm)
            extractor.options = Pipeline.extractorOptions(provider)
            let name = provider.name
            let result = try await extractor.extract(dump) { [weak self] done, total in
                Task { @MainActor in self?.showProgress("Reading your dump \(min(done + 1, total)) of \(total) · \(name)") }
            }
            matchProvider = provider
            matcher = LLMTopicMatcher(provider: provider.llm)
            await route(result.items)
        } catch {
            await local?.unload()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Progress callbacks arrive as separate tasks and can land after extraction has moved on to review;
    /// they only update the status while the processing screen is still showing.
    private func showProgress(_ status: String) {
        if case .processing = phase { phase = .processing(status) }
    }

    /// Shows every item as a card. Notes file themselves in the background; actions wait for ✓ unless
    /// their connector is auto-approved in Settings.
    private func route(_ items: [ExtractedItem]) async {
        review = items.map { ReviewEntry(item: $0) }
        phase = .review
        let auto = Prefs.autoApproved
        matchTask = Task { [weak self] in
            // Notes first: they save themselves, so the user sees them settle; then topics for the actions.
            for item in items.filter({ !$0.kind.isActionable }) + items.filter(\.kind.isActionable) {
                guard let self, !Task.isCancelled else { break }
                if item.kind.isActionable {
                    await self.findTopic(for: item.id)
                    if let c = self.connector(for: item), auto.contains(c.id) { await self.approve(item.id) }
                } else {
                    await self.file(item.id)
                }
            }
        }
    }

    // MARK: Review

    /// Where the item would go, or nil when no enabled connector handles it.
    func destination(for item: ExtractedItem) -> (text: String, icon: String)? {
        guard let store, let (c, category) = Pipeline.route(item.kind, in: Pipeline.enabledConnectors(store: store)) else { return nil }
        let icons = [Destination.reminders.rawValue: "checklist", Destination.calendar.rawValue: "calendar"]
        return (c.destination(for: item, category: category), icons[c.id] ?? "folder")
    }

    private func connector(for item: ExtractedItem) -> (any Connector)? {
        guard let store else { return nil }
        return Pipeline.route(item.kind, in: Pipeline.enabledConnectors(store: store))?.connector
    }

    private func index(_ id: UUID) -> Int? { review.firstIndex { $0.id == id } }

    /// ✓ on an action card: creates the reminder or event now, and lists it in its topic note if it has one.
    func approve(_ id: UUID) async {
        guard let i = index(id), review[i].isAction, review[i].status == .pending || review[i].status.isFailure else { return }
        review[i].status = .working
        let item = review[i].item
        do {
            let result = try await apply(item)
            guard let j = index(id) else { return }
            review[j].result = result
            review[j].status = .done
            if let topic = review[j].topic, let store, let journal {
                let line = result.summary.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? item.title
                try? store.appendTask(to: topic.url, text: line, journal: journal, date: Date())
            }
        } catch {
            if let j = index(id) { review[j].status = .failed(error.localizedDescription) }
        }
    }

    func approveAll() {
        Task {
            for entry in review where entry.isAction && entry.status == .pending { await approve(entry.id) }
        }
    }

    /// ✕ on a card: undoes whatever was applied (reminder, event or saved note) and dims the card.
    func dismiss(_ id: UUID) async {
        guard let i = index(id) else { return }
        if let result = review[i].result { await undoQuietly(result) }
        guard let j = index(id) else { return }
        review[j].result = nil
        review[j].status = .dismissed
    }

    /// Brings a dismissed card back: actions wait for ✓ again, notes are filed again.
    func restore(_ id: UUID) async {
        guard let i = index(id), review[i].status == .dismissed else { return }
        if review[i].isAction { review[i].status = .pending } else { await file(id) }
    }

    /// Changes a card's kind, undoing anything already applied for the old kind.
    func changeKind(_ id: UUID, to kind: ItemKind) async {
        guard let i = index(id), review[i].item.kind != kind else { return }
        if let result = review[i].result { await undoQuietly(result) }
        guard let j = index(id) else { return }
        review[j].result = nil
        review[j].topic = nil
        review[j].item.kind = kind
        review[j].item.addTo = nil
        if kind.isActionable {
            review[j].status = .pending
            await findTopic(for: id)
        } else {
            await file(id)
        }
    }

    /// Moves a saved note to another topic, or to a new topic of its own when `topic` is nil.
    func move(_ id: UUID, to topic: TopicMatch?) async {
        guard let i = index(id), !review[i].isAction else { return }
        if let result = review[i].result { await undoQuietly(result) }
        await save(id, into: topic)
    }

    /// Existing topics, for the "Move to" menu.
    func topics() -> [TopicMatch] {
        let dir = Prefs.notesRoot.appendingPathComponent("Notes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "md" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
                ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            .map { url in
                let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return TopicMatch(url: url, title: RelatedNotes.parse(raw, fallback: url.deletingPathExtension().lastPathComponent).title, reason: "")
            }
    }

    func skipAll() { finish() }

    /// Ends the review: stops filing, frees the model, records what was applied in the journal.
    func finish() {
        Task {
            await endMatching()
            results = review.compactMap { $0.status == .done ? $0.result : nil }
            for entry in review where entry.status == .done { kindByItem[entry.id] = entry.item.kind }
            failures = review.compactMap {
                if case .failed(let message) = $0.status { return Failure(title: $0.item.title, message: message) }
                return nil
            }
            finishToSummary()
        }
    }

    // MARK: Filing notes into topics

    /// Finds the topic a note belongs to and saves it there (or as a new topic).
    private func file(_ id: UUID) async {
        guard let i = index(id) else { return }
        review[i].status = .working
        let item = review[i].item
        let match = await matcher?.match(title: item.title, text: matchQuote(item), root: Prefs.notesRoot)
        await save(id, into: match)
    }

    private func save(_ id: UUID, into topic: TopicMatch?) async {
        guard let i = index(id) else { return }
        review[i].status = .working
        var item = review[i].item
        item.addTo = topic?.url
        do {
            let result = try await apply(item)
            guard let j = index(id) else { return }
            review[j].item.addTo = topic?.url
            review[j].result = result
            review[j].topic = topic
            review[j].status = .done
        } catch {
            if let j = index(id) { review[j].status = .failed(error.localizedDescription) }
        }
    }

    /// For an action: the topic note it should be listed in once approved.
    private func findTopic(for id: UUID) async {
        guard let i = index(id) else { return }
        let item = review[i].item
        let match = await matcher?.match(title: item.title, text: matchQuote(item), root: Prefs.notesRoot)
        if let j = index(id) { review[j].topic = match }
    }

    /// The item's words plus the sentence before it when that one is short: "On Braindump. I need to build a
    /// website for it" should match notes about Brain Dump even though only the second sentence was cited.
    private func matchQuote(_ item: ExtractedItem) -> String {
        guard let first = item.sentenceIndices.min(), first > 0,
              let previous = sentences.first(where: { $0.index == first - 1 }),
              previous.text.split(whereSeparator: \.isWhitespace).count <= 5 else { return item.quote }
        return previous.text + " " + item.quote
    }

    /// Runs the item's connector, asking for Reminders or Calendar access the first time.
    private func apply(_ item: ExtractedItem) async throws -> ActionResult {
        guard let store, let journal, let (c, category) = Pipeline.route(item.kind, in: Pipeline.enabledConnectors(store: store)) else {
            throw AppError("No connector is switched on for \(item.kind.label).")
        }
        if c.id == Destination.reminders.rawValue, !(await RemindersConnector.requestAccess()) {
            throw AppError("Reminders access is off. Allow Brain Dump in System Settings › Privacy & Security › Reminders.")
        }
        if c.id == Destination.calendar.rawValue, !(await CalendarConnector.requestAccess()) {
            throw AppError("Calendar access is off. Allow Brain Dump in System Settings › Privacy & Security › Calendars.")
        }
        return try await c.execute(item, context: ActionContext(journal: journal, now: Date(), category: category))
    }

    private func undoQuietly(_ result: ActionResult) async {
        guard let store else { return }
        try? await Pipeline.connectors(store: store).first { $0.id == result.connectorID }?.undo(result)
    }

    private func unloadMatchProvider() async {
        await matchProvider?.local?.unload()
        matchProvider = nil
        matcher = nil
    }

    /// Stops filing and frees the model.
    private func endMatching() async {
        matchTask?.cancel()
        await matchTask?.value
        matchTask = nil
        await unloadMatchProvider()
    }

    // MARK: Cards from selected transcript text

    /// Sentence ranges (UTF-16) within the trimmed dump, in order.
    func sentenceRanges() -> [(index: Int, range: NSRange)] {
        let dump = text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        var cursor = 0
        var out: [(Int, NSRange)] = []
        for sentence in sentences {
            let r = dump.range(of: sentence.text, range: NSRange(location: cursor, length: dump.length - cursor))
            guard r.location != NSNotFound else { continue }
            cursor = r.location + r.length
            out.append((sentence.index, r))
        }
        return out
    }

    /// Adds a card made from highlighted transcript text. A note is filed straight away; an action waits for ✓.
    func addManual(kind: ItemKind, selection: String, range: NSRange) {
        let quote = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return }
        var item = ExtractedItem(
            kind: kind, title: Self.truncate(Extractor.fallbackTitle(quote), to: 80),
            sentenceIndices: sentenceRanges().filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.index),
            quote: quote)
        if kind.isActionable, let found = DateResolver().firstDate(in: quote) {
            item.due = found.resolved.date
            item.dueHasTime = found.resolved.hasTime
            item.whenText = found.phrase
        }
        review.append(ReviewEntry(item: item))
        focusedItem = item.id
        Task { if kind.isActionable { await findTopic(for: item.id) } else { await file(item.id) } }
    }

    static func truncate(_ s: String, to limit: Int) -> String {
        let one = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard one.count > limit else { return one }
        let cut = String(one.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }

    private func finishToSummary() {
        loadHome()
        if let store, let journal, !results.isEmpty {
            try? store.appendActions(results.map(\.summary), to: journal)
        }
        phase = .summary
    }

    // MARK: Summary

    func undo(_ result: ActionResult) {
        guard let store else { return }
        let connector = Pipeline.connectors(store: store).first { $0.id == result.connectorID }
        Task {
            do {
                try await connector?.undo(result)
                undone.insert(result.id)
                undoErrors[result.id] = nil
            } catch {
                undoErrors[result.id] = error.localizedDescription
            }
        }
    }

    func openJournal() {
        if let url = journal?.url { openNote(url) }
    }

    /// Shows a note in the Notes section, or a journal entry in the Journal section.
    func openNote(_ url: URL) {
        selectedNote = url
        notesShowGraph = false
        section = url.deletingLastPathComponent().lastPathComponent == "Journal" ? .journal : .notes
    }

    /// Shows the graph in the Notes section.
    func openGraph() {
        section = .notes
        notesShowGraph = true
    }
}
