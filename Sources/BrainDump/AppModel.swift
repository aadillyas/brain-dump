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
    var item: ExtractedItem
    var selected: Bool
    var id: UUID { item.id }
}

struct RelatedChoice: Identifiable {
    let note: RelatedNote
    var approved = false
    var id: URL { note.url }
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
    var results: [ActionResult] = []
    var failures: [Failure] = []
    var undone: Set<UUID> = []
    var undoErrors: [UUID: String] = [:]
    var sentences: [Sentence] = []
    /// The card being hovered or selected; its quote is highlighted in the transcript.
    var focusedItem: UUID?
    var kindByItem: [UUID: ItemKind] = [:]
    var showLibrary = false
    var librarySelection: URL?
    var showIntro = !Prefs.introSeen
    var related: [UUID: [RelatedChoice]] = [:]
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
        related = [:]
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
        do {
            let provider = try await Pipeline.provider(cloud: Prefs.useCloud, local: Prefs.localModel) { [weak self] status in
                Task { @MainActor in self?.phase = .processing(status) }
            }
            local = provider.local
            phase = .processing("Reading your dump…")
            let result = try await Extractor(provider: provider.llm).extract(dump) { [weak self] done, total in
                Task { @MainActor in self?.phase = .processing("Reading your dump \(min(done + 1, total)) of \(total)") }
            }
            await local?.unload()
            await route(result.items)
        } catch {
            await local?.unload()
            phase = .failed(error.localizedDescription)
        }
    }

    private func route(_ items: [ExtractedItem]) async {
        guard let store else { return }
        let connectors = Pipeline.enabledConnectors(store: store)
        let auto = Prefs.autoApproved
        var manual: [ReviewEntry] = []
        var automatic: [ExtractedItem] = []
        for item in items {
            if let c = Pipeline.connector(for: item.kind, in: connectors) {
                if auto.contains(c.id) { automatic.append(item) } else { manual.append(ReviewEntry(item: item, selected: !item.lowConfidence)) }
            } else {
                manual.append(ReviewEntry(item: item, selected: false))
            }
        }
        if !automatic.isEmpty {
            phase = .processing("Creating items…")
            await execute(automatic)
        }
        review = []
        if manual.isEmpty && !items.isEmpty { finishToSummary(); return }
        phase = .review
        for entry in manual { scanRelated(for: entry.item) }
        // Extraction delivers everything at once; let the cards arrive one by one.
        for entry in manual {
            withAnimation(.easeOut(duration: 0.3)) { review.append(entry) }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    // MARK: Review

    /// Where the item would go, or nil when no enabled connector handles it.
    func destination(for item: ExtractedItem) -> (text: String, icon: String)? {
        guard let store, let c = Pipeline.connector(for: item.kind, in: Pipeline.enabledConnectors(store: store)) else { return nil }
        return (c.destination(for: item), c.id == "reminders" ? "checklist" : "folder")
    }

    func apply() {
        let chosen = review.filter(\.selected).map(\.item).filter { destination(for: $0) != nil }
        Task {
            phase = .processing("Adding \(chosen.count) item\(chosen.count == 1 ? "" : "s")…")
            await execute(chosen)
            finishToSummary()
        }
    }

    func skipAll() { finishToSummary() }

    // MARK: Related notes

    /// Looks for similar existing notes off the main thread. Only Ideas and Thoughts are scanned for.
    func scanRelated(for item: ExtractedItem) {
        guard !item.kind.isActionable else { return }
        guard related[item.id] == nil else { return }
        let root = Prefs.notesRoot, title = item.title, quote = item.quote, id = item.id
        Task {
            let found = await Task.detached(priority: .utility) {
                RelatedNotes.find(title: title, quote: quote, root: root)
            }.value
            if related[id] == nil { related[id] = found.map { RelatedChoice(note: $0) } }
        }
    }

    func toggleRelated(item: UUID, note: URL) {
        guard let i = related[item]?.firstIndex(where: { $0.note.url == note }) else { return }
        related[item]?[i].approved.toggle()
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

    /// Adds a pre-approved card made from highlighted transcript text.
    func addManual(kind: ItemKind, selection: String, range: NSRange) {
        let quote = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return }
        var item = ExtractedItem(
            kind: kind, title: Self.truncate(quote, to: 80),
            sentenceIndices: sentenceRanges().filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.index),
            quote: quote)
        if kind.isActionable {
            if let found = DateResolver().firstDate(in: quote) {
                item.kind = .reminder
                item.due = found.resolved.date
                item.dueHasTime = found.resolved.hasTime
                item.whenText = found.phrase
            } else {
                item.kind = .task
                item.due = Calendar.current.startOfDay(for: Date())
            }
        }
        withAnimation(.easeOut(duration: 0.3)) { review.append(ReviewEntry(item: item, selected: true)) }
        focusedItem = item.id
        scanRelated(for: item)
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

    private func execute(_ items: [ExtractedItem]) async {
        guard let store, let journal else { return }
        let connectors = Pipeline.enabledConnectors(store: store)
        var remindersAllowed: Bool?
        for item in items {
            guard let c = Pipeline.connector(for: item.kind, in: connectors) else { continue }
            if c.id == "reminders" {
                if remindersAllowed == nil { remindersAllowed = await RemindersConnector.requestAccess() }
                if remindersAllowed == false {
                    failures.append(Failure(title: item.title, message: "Reminders access was denied. Allow Brain Dump in System Settings › Privacy & Security › Reminders."))
                    continue
                }
            }
            do {
                let result = try await c.execute(item, context: ActionContext(journal: journal, now: Date()))
                results.append(result)
                kindByItem[item.id] = item.kind
                if let url = result.openURL, c.id == "notes" { linkRelated(item, newNote: url, store: store) }
            } catch {
                failures.append(Failure(title: item.title, message: error.localizedDescription))
            }
        }
    }

    /// Writes each approved related link into both notes.
    private func linkRelated(_ item: ExtractedItem, newNote url: URL, store: NotesStore) {
        let approved = (related[item.id] ?? []).filter(\.approved)
        guard !approved.isEmpty else { return }
        let new = NoteRef(url: url, wikiLink: url.deletingLastPathComponent().lastPathComponent + "/" + url.deletingPathExtension().lastPathComponent)
        for choice in approved {
            let old = NoteRef(url: choice.note.url, wikiLink: choice.note.wikiLink)
            try? store.addRelatedLink(from: new, to: old)
            try? store.addRelatedLink(from: old, to: new)
        }
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

    /// Opens a note in the in-app Library viewer.
    func openNote(_ url: URL) {
        librarySelection = url
        showLibrary = true
    }
}
