import BrainDumpCore
import Foundation

var total = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    total += 1
    if !condition {
        failed += 1
        print("FAIL: \(name)")
    }
}

// MARK: - DateResolver

let colombo = TimeZone(identifier: "Asia/Colombo")!
var cal = Calendar(identifier: .gregorian)
cal.timeZone = colombo
cal.firstWeekday = 2
cal.locale = Locale(identifier: "en_US_POSIX")

func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

let now = at(2026, 11, 11, 7, 30)
let resolver = DateResolver(now: now, calendar: cal)
let afternoon = DateResolver(now: at(2026, 11, 11, 14, 0), calendar: cal)

func expect(_ phrase: String, _ date: Date, time: Bool, using r: DateResolver = resolver) {
    let got = r.resolve(phrase)
    check(got == ResolvedDate(date: date, hasTime: time), "resolve \"\(phrase)\" -> \(String(describing: got))")
}

func expectNil(_ phrase: String, using r: DateResolver = resolver) {
    let got = r.resolve(phrase)
    check(got == nil, "resolve \"\(phrase)\" should be nil, got \(String(describing: got))")
}

// days
expect("today", at(2026, 11, 11), time: false)
expect("tonight", at(2026, 11, 11, 20), time: true)
expect("tomorrow", at(2026, 11, 12), time: false)
expect("Tomorrow", at(2026, 11, 12), time: false)
expect("day after tomorrow", at(2026, 11, 13), time: false)
expect("friday", at(2026, 11, 13), time: false)
expect("this friday", at(2026, 11, 13), time: false)
expect("this coming Friday", at(2026, 11, 13), time: false)
expect("by Friday", at(2026, 11, 13), time: false)
expect("fri", at(2026, 11, 13), time: false)
expect("next friday", at(2026, 11, 20), time: false)
expect("wednesday", at(2026, 11, 11), time: false)
expect("next wednesday", at(2026, 11, 18), time: false)
expect("monday", at(2026, 11, 16), time: false)
expect("next monday", at(2026, 11, 16), time: false)
expect("sunday", at(2026, 11, 15), time: false)
expect("next week", at(2026, 11, 16), time: false)
expect("this weekend", at(2026, 11, 14), time: false)
expect("the weekend", at(2026, 11, 14), time: false)
expect("end of the week", at(2026, 11, 13), time: false)
expect("end of day", at(2026, 11, 11, 17), time: true)
expect("eod", at(2026, 11, 11, 17), time: true)
expect("end of the day", at(2026, 11, 11, 17), time: true)
expect("in 3 days", at(2026, 11, 14), time: false)
expect("in two weeks", at(2026, 11, 25), time: false)
expect("in a week", at(2026, 11, 18), time: false)
expect("in a couple of days", at(2026, 11, 13), time: false)
expect("in an hour", at(2026, 11, 11, 8, 30), time: true)
expect("in 45 minutes", at(2026, 11, 11, 8, 15), time: true)
expect("in 2 hours", at(2026, 11, 11, 9, 30), time: true)
expect("November 20th", at(2026, 11, 20), time: false)
expect("20th of November", at(2026, 11, 20), time: false)
expect("Nov 20", at(2026, 11, 20), time: false)
expect("the 20th", at(2026, 11, 20), time: false)
expect("on the 5th", at(2026, 12, 5), time: false)
expect("the 11th", at(2026, 11, 11), time: false)
expect("Nov 10", at(2027, 11, 10), time: false)
expect("20 november", at(2026, 11, 20), time: false)
expectNil("feb 30")

// times
expect("3pm", at(2026, 11, 11, 15), time: true)
expect("3 pm", at(2026, 11, 11, 15), time: true)
expect("3:30pm", at(2026, 11, 11, 15, 30), time: true)
expect("3 p.m.", at(2026, 11, 11, 15), time: true)
expect("15:00", at(2026, 11, 11, 15), time: true)
expect("at 3", at(2026, 11, 11, 15), time: true)
expect("at 3:30", at(2026, 11, 11, 15, 30), time: true)
expect("at 9", at(2026, 11, 11, 9), time: true)
expect("at 8", at(2026, 11, 11, 8), time: true)
expect("at 12", at(2026, 11, 11, 12), time: true)
expect("at three", at(2026, 11, 11, 15), time: true)
expect("3 o'clock", at(2026, 11, 11, 15), time: true)
expect("noon", at(2026, 11, 11, 12), time: true)
expect("midday", at(2026, 11, 11, 12), time: true)
expect("midnight", at(2026, 11, 12, 0), time: true)
expect("morning", at(2026, 11, 11, 9), time: true)
expect("afternoon", at(2026, 11, 11, 14), time: true)
expect("evening", at(2026, 11, 11, 18), time: true)
expect("lunch", at(2026, 11, 11, 12, 30), time: true)
expect("lunchtime", at(2026, 11, 11, 12, 30), time: true)
expect("half past 3", at(2026, 11, 11, 15, 30), time: true)
expect("quarter past 3", at(2026, 11, 11, 15, 15), time: true)
expect("quarter to 4", at(2026, 11, 11, 15, 45), time: true)
expect("7am", at(2026, 11, 12, 7), time: true)
expect("7:45 am", at(2026, 11, 11, 7, 45), time: true)
expect("12am", at(2026, 11, 12, 0), time: true)
expect("before noon", at(2026, 11, 11, 12), time: true)

// combinations
expect("tomorrow morning", at(2026, 11, 12, 9), time: true)
expect("tomorrow afternoon", at(2026, 11, 12, 14), time: true)
expect("tomorrow evening", at(2026, 11, 12, 18), time: true)
expect("Friday at 3", at(2026, 11, 13, 15), time: true)
expect("friday morning", at(2026, 11, 13, 9), time: true)
expect("tomorrow at 3:30pm", at(2026, 11, 12, 15, 30), time: true)
expect("next friday at 10am", at(2026, 11, 20, 10), time: true)
expect("monday at 9", at(2026, 11, 16, 9), time: true)
expect("at 3 tomorrow", at(2026, 11, 12, 15), time: true)
expect("this morning", at(2026, 11, 11, 9), time: true)
expect("Nov 20 at noon", at(2026, 11, 20, 12), time: true)
expect("tonight at 9pm", at(2026, 11, 11, 21), time: true)
expect("in 3 days at 2pm", at(2026, 11, 14, 14), time: true)

// nil cases
expectNil("yesterday")
expectNil("last week")
expectNil("last friday")
expectNil("yesterday at 3pm")
expectNil("this morning", using: afternoon)
expectNil("today at 7am")
expectNil("end of day", using: DateResolver(now: at(2026, 11, 11, 18), calendar: cal))
expectNil("tonight", using: DateResolver(now: at(2026, 11, 11, 21), calendar: cal))
expectNil("Nov 2 2026")
expectNil("banana")
expectNil("")
expectNil("may")
expectNil("5")
expectNil("the second")
expect("morning", at(2026, 11, 12, 9), time: true, using: afternoon)
expect("3pm", at(2026, 11, 11, 15), time: true, using: afternoon)

// firstDate
func first(_ text: String, _ date: Date?, time: Bool = false, phrase: String? = nil) {
    let got = resolver.firstDate(in: text)
    if let date {
        check(got?.resolved == ResolvedDate(date: date, hasTime: time), "firstDate \"\(text)\" -> \(String(describing: got))")
        if let phrase { check(got?.phrase == phrase, "firstDate phrase \"\(text)\" -> \(String(describing: got?.phrase))") }
    } else {
        check(got == nil, "firstDate \"\(text)\" should be nil, got \(String(describing: got))")
    }
}

first("Remind me to call the dentist tomorrow at 3pm", at(2026, 11, 12, 15), time: true, phrase: "tomorrow at 3pm")
first("I need to finish the report by Friday", at(2026, 11, 13), phrase: "Friday")
first("Meet Sarah at 3 near the station", at(2026, 11, 11, 15), time: true, phrase: "at 3")
first("Pick up the kids this afternoon", at(2026, 11, 11, 14), time: true, phrase: "this afternoon")
first("Call mom on the 20th of November", at(2026, 11, 20), phrase: "the 20th of November")
first("Dentist on Friday and gym tomorrow", at(2026, 11, 13), phrase: "Friday")
first("I called him yesterday and I will call again tomorrow", at(2026, 11, 12), phrase: "tomorrow")
first("Send the invoice in the morning", at(2026, 11, 11, 9), time: true, phrase: "in the morning")
first("Renew the passport in 2 weeks", at(2026, 11, 25), phrase: "in 2 weeks")
first("Email Bob. Next week we ship", at(2026, 11, 16), phrase: "Next week")
first("It is due Friday. 3 people are coming", at(2026, 11, 13), phrase: "Friday")
first("Lunch with Ana tomorrow, at 1pm", at(2026, 11, 12, 13), time: true, phrase: "tomorrow, at 1pm")
first("Book flights before lunch", at(2026, 11, 11, 12, 30), time: true, phrase: "lunch")
first("Call him on Mon", at(2026, 11, 16), phrase: "Mon")
first("Taxes are due May 5", at(2027, 5, 5), phrase: "May 5")
first("Wrap up by eod", at(2026, 11, 11, 17), time: true, phrase: "eod")
first("Quarter to 4 is the deadline", at(2026, 11, 11, 15, 45), time: true, phrase: "Quarter to 4")
first("I sat down and thought it may rain", nil)
first("The sun was out and I felt good", nil)
first("I will call Mon", nil)
first("The second option is better", nil)
first("I have 5 things to do and 3 calls", nil)
first("We talked for 3 hours", nil)
first("Good morning, I woke up early", nil)
first("I had lunch with Bob", nil)
first("I want to march in the parade", nil)
first("He was born in 1990", nil)
first("It happened yesterday at 3pm", nil)
first("Last friday was great", nil)
first("I feel like I am not making progress", nil)
first("Every morning I check email", nil)

// MARK: - Segmenter

let sentences = Segmenter.sentences(in: "Call Bob. Buy milk! Is the report done?")
check(sentences.count == 3, "segmenter splits 3 sentences, got \(sentences.count)")
check(sentences.map(\.index) == [0, 1, 2], "segmenter indices")
check(sentences.first?.text == "Call Bob.", "segmenter first text")
check(Segmenter.sentences(in: "   ").isEmpty, "segmenter empty")

var runOn: [String] = []
for i in 0..<12 { runOn.append("I need to handle thing number \(i) today, and then I should also check the other stuff") }
let longText = runOn.joined(separator: " ") + "."
let longWords = longText.split(separator: " ").count
let longSentences = Segmenter.sentences(in: longText)
check(longSentences.count > 3, "run-on split into several, got \(longSentences.count)")
check(longSentences.allSatisfy { $0.text.split(separator: " ").count <= Segmenter.maxSentenceWords + 3 }, "run-on pieces bounded")
check(longSentences.map { $0.text.split(separator: " ").count }.reduce(0, +) == longWords, "run-on keeps every word")

let sample = (0..<25).map { Sentence(index: $0, text: Array(repeating: "word", count: 30).joined(separator: " ")) }
let chunks = Segmenter.chunks(sample)
check(chunks.allSatisfy { $0.count <= 9 }, "chunk line limit")
check(chunks.allSatisfy { $0.map { $0.text.split(separator: " ").count }.reduce(0, +) <= 110 }, "chunk word limit")
check(chunks.flatMap { $0 } == sample, "chunks keep order and content")
check(Segmenter.chunks([]).isEmpty, "chunks empty")

// MARK: - NotesStore

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("braindump-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }
let store = NotesStore(root: tmp)
let localCal = Calendar.current
let day1 = localCal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 7, minute: 30))!
let day1b = localCal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 21, minute: 5))!

func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

do {
    try store.prepare()
    for sub in ["Journal"] {
        var isDir: ObjCBool = false
        check(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(sub).path, isDirectory: &isDir) && isDir.boolValue, "prepare creates \(sub)")
    }

    let journal = try store.writeJournal(text: "First thoughts of the day.", date: day1)
    check(journal.wikiLink == "Journal/2026-11-11#07:30", "journal wikiLink \(journal.wikiLink)")
    check(journal.url.lastPathComponent == "2026-11-11.md", "journal filename")
    var text = read(journal.url)
    check(text.hasPrefix("---\ndate: 2026-11-11\ntype: journal\n---\n"), "journal frontmatter")
    check(text.contains("# Wednesday 11 November 2026"), "journal heading")
    check(text.contains("## 07:30\n\nFirst thoughts of the day."), "journal first section")

    let again = try store.writeJournal(text: "Evening addition.", date: day1b)
    check(again.url == journal.url && again.wikiLink == "Journal/2026-11-11#21:05", "same-day journal: same file, new section")
    text = read(journal.url)
    check(text.contains("## 21:05\n\nEvening addition."), "journal append section")
    check(text.components(separatedBy: "type: journal").count == 2, "journal frontmatter not duplicated")
    check(text.range(of: "## 07:30")!.lowerBound < text.range(of: "## 21:05")!.lowerBound, "journal sections in order")

    let idea = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: "Voice journal app!", body: "What if it was an app", journal: journal, date: day1)
    check(idea.wikiLink == "Notes/voice-journal-app", "idea wikiLink \(idea.wikiLink)")
    let ideaText = read(idea.url)
    check(ideaText.contains("type: note"), "idea type")
    check(ideaText.contains("created: 2026-11-11T07:30:00"), "idea created iso")
    check(ideaText.contains("mentions: 1"), "idea mentions")
    check(ideaText.contains("# Voice journal app!\n\n## Log\n\n### 2026-11-11 07:30 · [[Journal/2026-11-11#07:30]]\n\n> What if it was an app\n"), "idea log entry")

    let previous = try store.appendMention(to: idea.url, quote: "Still thinking about the app", journal: again, date: day1b)
    let merged = read(idea.url)
    check(previous == ideaText, "appendMention returns previous content")
    check(merged.contains("mentions: 2") && !merged.contains("mentions: 1"), "mention count bumped")
    check(merged.contains("updated: 2026-11-11T21:05:00"), "updated bumped")
    check(merged.components(separatedBy: "updated:").count == 2, "single updated line")
    let newer = merged.range(of: "Still thinking")!.lowerBound, older = merged.range(of: "What if it was")!.lowerBound
    check(newer < older, "newest mention first")
    check(!merged.contains("\n\n\n"), "no triple newlines after merge")
    try store.restore(idea.url, content: previous)
    check(read(idea.url) == ideaText, "restore undoes the merge")

    // A note in the format used before living notes gains a Log section.
    try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    let legacy = tmp.appendingPathComponent("Notes/legacy.md")
    try "---\ntype: idea\ncreated: 2026-11-01T08:00:00Z\nsource: \"[[Journal/2026-11-01]]\"\n---\n\n# Legacy\n\nOld words.\n\nFrom [[Journal/2026-11-01]]\n\n## Related\n\n- [[Notes/x]]\n".write(to: legacy, atomically: true, encoding: .utf8)
    try store.appendMention(to: legacy, quote: "New words", journal: again, date: day1b)
    let legacyText = read(legacy)
    check(legacyText.contains("mentions: 2"), "legacy mentions")
    check(legacyText.range(of: "## Log")!.lowerBound < legacyText.range(of: "## Related")!.lowerBound, "legacy log before related")
    check(RelatedNotes.parse(legacyText, fallback: "x").body.contains("New words"), "parse reads log quotes")
    try FileManager.default.removeItem(at: legacy)

    try store.appendTask(to: idea.url, text: "Build a website — Friday", journal: again, date: day1b)
    try store.appendTask(to: idea.url, text: "Record intro video", journal: again, date: day1b)
    let tasked = read(idea.url)
    check(tasked.contains("## Tasks\n\n- [ ] Build a website — Friday · [[Journal/2026-11-11#21:05]]\n- [ ] Record intro video · [[Journal/2026-11-11#21:05]]\n\n## Log"), "tasks section before log")
    check(tasked.components(separatedBy: "updated:").count == 2 && tasked.contains("updated: 2026-11-11T21:05:00"), "task bumps updated once")
    try store.restore(idea.url, content: ideaText)

    let dup = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: "Voice journal app!", body: "again", journal: journal, date: day1)
    check(dup.wikiLink == "Notes/voice-journal-app-2", "slug collision -2, got \(dup.wikiLink)")
    let dup3 = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: "voice journal app", body: "again", journal: journal, date: day1)
    check(dup3.wikiLink == "Notes/voice-journal-app-3", "slug collision -3, got \(dup3.wikiLink)")

    let thought = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: "Am I doing enough", body: "Worried", journal: journal, date: day1)
    check(thought.url.deletingLastPathComponent().lastPathComponent == "Notes", "note folder")
    check(read(thought.url).contains("type: note"), "reflection type")
    let odd = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: "???", body: "x", journal: journal, date: day1)
    check(odd.wikiLink == "Notes/note", "empty slug fallback, got \(odd.wikiLink)")
    let longTitle = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: String(repeating: "abcdefghij ", count: 20), body: "x", journal: journal, date: day1)
    check(longTitle.url.deletingPathExtension().lastPathComponent.count <= 60, "slug max 60")
    check(NotesStore.slug("  Café  --  Déjà Vu! ") == "cafe-deja-vu", "slug folding \(NotesStore.slug("  Café  --  Déjà Vu! "))")

    try store.appendActions([], to: journal)
    let before = read(journal.url)
    check(!before.contains("### Actions"), "empty actions is a no-op")
    try store.appendActions(["Reminder: Call the dentist — tomorrow 9:00", "Task: Send report"], to: journal)
    text = read(journal.url)
    check(text.hasSuffix("### Actions\n\n- Reminder: Call the dentist — tomorrow 9:00\n- Task: Send report\n"), "actions appended at end")

    try store.delete(idea)
    check(!FileManager.default.fileExists(atPath: idea.url.path), "delete removes file")
    check(FileManager.default.fileExists(atPath: dup.url.path), "delete leaves siblings")
} catch {
    check(false, "NotesStore threw: \(error)")
}

// Related notes
let kwA = RelatedNotes.keywords("I should start a morning walking routine to clear my head")
check(kwA.contains("walking") && !kwA.contains("the") && !kwA.contains("to"), "keywords drop stopwords")
let kwB = RelatedNotes.keywords("Morning walking helps clear the head before work")
let kwC = RelatedNotes.keywords("Quarterly budget spreadsheet for the accountant")
check(RelatedNotes.keywordScore(kwA, kwB) >= RelatedNotes.keywordThreshold, "related text scores above keyword threshold")
check(RelatedNotes.keywordScore(kwA, kwC) == 0, "unrelated text scores zero")
check(RelatedNotes.score(keywordScore: 0.3, sharedKeywords: 1, cosine: nil) == nil, "one shared word is not enough without embedding")
check(RelatedNotes.score(keywordScore: 0.3, sharedKeywords: 3, cosine: nil) != nil, "keyword-only fallback passes")
check(RelatedNotes.score(keywordScore: 0.1, sharedKeywords: 1, cosine: 0.3) == nil, "unrelated embedding stays below threshold")
check(RelatedNotes.score(keywordScore: 0.4, sharedKeywords: 3, cosine: 0.85) != nil, "strong embedding passes")

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bd-related-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotesStore(root: root)
    let j = try store.writeJournal(text: "Walk idea.", date: now)
    let a = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: "Morning walking routine", body: "Walk every morning to clear my head.", journal: j, date: now)
    let b = try store.createNote(category: ItemCategory.defaults.category(for: .note)!, title: "Quarterly budget", body: "The spreadsheet for the accountant is late.", journal: j, date: now)
    let found = RelatedNotes.find(title: "Walking before work", quote: "A morning walking habit would clear my head.", root: root)
    check(found.first?.wikiLink == a.wikiLink, "related finds the walking note")
    check(!found.contains { $0.wikiLink == b.wikiLink }, "related skips the unrelated note")
    check(RelatedNotes.find(title: "Walking", quote: "morning walking head", root: root, excluding: a.url).isEmpty, "related excludes the note itself")
    try store.addRelatedLink(from: a, to: b)
    try store.addRelatedLink(from: a, to: b)
    var t = try String(contentsOf: a.url, encoding: .utf8)
    check(t.contains("## Related\n\n- [[Notes/quarterly-budget]]\n"), "related section created")
    check(t.components(separatedBy: "[[Notes/quarterly-budget]]").count == 2, "related link not duplicated")
    try store.addRelatedLink(from: a, to: NoteRef(url: b.url, wikiLink: "Notes/other"))
    t = try String(contentsOf: a.url, encoding: .utf8)
    check(t.components(separatedBy: "## Related").count == 2 && t.contains("- [[Notes/other]]"), "second link joins existing section")
    check(!RelatedNotes.parse(t, fallback: "x").body.contains("Related"), "parse drops related section")
} catch {
    check(false, "related notes threw: \(error)")
}

// Journal index
do {
    let md = "---\ndate: 2026-11-11\n---\n\n# Wednesday\n\n## 07:30\n\nFirst line here.\nMore words.\n\n### Actions\n\n- Task: x\n\n## 18:05\n\nEvening dump\n"
    let es = JournalIndex.entries(in: md, fileName: "2026-11-11", url: URL(fileURLWithPath: "/tmp/x.md"), calendar: cal)
    check(es.count == 2, "journal index finds two sections")
    check(es.first?.preview == "First line here." && es.first?.words == 5, "journal index preview and words exclude actions")
    let day = { (d: Int) in JournalEntry(date: at(2026, 11, d, 9), url: URL(fileURLWithPath: "/tmp/\(d).md"), preview: "", words: 1) }
    check(JournalIndex.streak([day(11), day(10), day(9), day(7)], today: at(2026, 11, 11, 20), calendar: cal) == 3, "streak counts consecutive days")
    check(JournalIndex.streak([day(10), day(9)], today: at(2026, 11, 11, 20), calendar: cal) == 2, "streak survives a not-yet-dumped today")
    check(JournalIndex.streak([day(8)], today: at(2026, 11, 11, 20), calendar: cal) == 0, "streak breaks after a missed day")
}

// Reminders summary labels (no EventKit access needed)
let tomorrow9 = at(2026, 11, 12, 9)
check(RemindersConnector.describe(tomorrow9, hasTime: true, now: now, calendar: cal) == "tomorrow 9:00", "describe tomorrow 9:00")
check(RemindersConnector.describe(at(2026, 11, 13), hasTime: false, now: now, calendar: cal) == "Friday", "describe weekday")
check(RemindersConnector.describe(at(2026, 11, 20, 15, 30), hasTime: true, now: now, calendar: cal) == "20 Nov 15:30", "describe far date")
check(RemindersConnector(listName: nil).destination(for: ExtractedItem(kind: .todo, title: "t", sentenceIndices: [], quote: ""), category: ItemCategory.defaults[0]) == "Reminders › Default", "reminders destination default")
check(NotesConnector(store: store).destination(for: ExtractedItem(kind: .note, title: "t", sentenceIndices: [], quote: ""), category: ItemCategory.defaults[2]) == "Notes › Notes", "notes destination")

// MARK: - Legacy folder migration

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bd-migrate-\(UUID().uuidString)")
    let fm = FileManager.default
    for sub in ["Ideas", "Reflections", "Notes", "Journal"] { try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true) }
    try "---\ntype: idea\n---\n\n# App\n\n## Related\n\n- [[Reflections/tired]] — energy\n".write(to: root.appendingPathComponent("Ideas/app.md"), atomically: true, encoding: .utf8)
    try "---\ntype: reflection\n---\n\n# Tired\n\n## Related\n\n- [[Ideas/app]] — energy\n".write(to: root.appendingPathComponent("Reflections/tired.md"), atomically: true, encoding: .utf8)
    try "---\ntype: note\n---\n\n# Existing app\n".write(to: root.appendingPathComponent("Notes/app.md"), atomically: true, encoding: .utf8)
    try "# Day\n\nSee [[Ideas/app#Log]] and [[Reflections/tired|me]].\n".write(to: root.appendingPathComponent("Journal/2026-11-01.md"), atomically: true, encoding: .utf8)
    let moved = try NotesStore(root: root).migrateLegacyFolders()
    check(moved == 2, "migration moved 2 notes, got \(moved)")
    check(!fm.fileExists(atPath: root.appendingPathComponent("Ideas").path), "legacy folder removed")
    let app2 = read(root.appendingPathComponent("Notes/app-2.md"))
    check(app2.contains("type: note") && app2.contains("[[Notes/tired]] — energy"), "migrated note retyped and relinked")
    check(read(root.appendingPathComponent("Notes/tired.md")).contains("[[Notes/app-2]]"), "links follow clash rename")
    check(read(root.appendingPathComponent("Journal/2026-11-01.md")).contains("[[Notes/app-2#Log]] and [[Notes/tired|me]]"), "journal links rewritten")
    check(read(root.appendingPathComponent("Notes/app.md")) == "---\ntype: note\n---\n\n# Existing app\n", "existing note untouched")
    check(try NotesStore(root: root).migrateLegacyFolders() == 0, "migration is a no-op the second time")
}

// MARK: - ReviewDigest

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bd-review-\(UUID().uuidString)")
    let fm = FileManager.default
    for sub in ["Notes", "Journal"] { try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true) }
    func put(_ path: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = 2
    try put("Journal/2026-11-10.md", "---\ntype: journal\n---\n\n# Tuesday 10 November 2026\n\n## 08:00\n\nOne two three four five\n\n### Actions\n\n- To-do: Buy milk — tomorrow 16:00\n- Note added to: Brain Dump app\n\n## 09:30\n\nSix seven\n")
    try put("Journal/2026-11-11.md", "# Wed\n\n## 07:00\n\nHello there\n\n### Actions\n\n- Event: Call with Jeb — tomorrow 15:00\n")
    try put("Journal/2026-11-03.md", "# Old\n\n## 07:00\n\nLast week\n\n### Actions\n\n- To-do: Old thing\n")
    try put("Journal/garbage.md", "## 99:xx\nnonsense")
    try put("Notes/brain-dump-app.md", "---\ntype: note\ncreated: 2026-11-10T08:00:00Z\nupdated: 2026-11-11T07:00:00Z\nmentions: 2\n---\n\n# Brain Dump app\n\n## Tasks\n\n- [ ] Ship review · [[Journal/2026-11-11]]\n- [x] Done thing\n\n## Log\n\n### 2026-11-11 07:00 · [[Journal/2026-11-11#07:00]]\n\n> Hello there\n> second line\n\n### 2026-11-10 08:00 · [[Journal/2026-11-10#08:00]]\n\n> One two\n\n## Related\n\n- [[Notes/x]]\n")
    try put("Notes/gym.md", "---\ntype: note\ncreated: 2026-10-01T08:00:00Z\nmentions: 4\n---\n\n# Gym\n\n## Log\n\n### 2026-10-20 08:00 · [[Journal/2026-10-20#08:00]]\n\n> lifted\n")
    try put("Notes/old.md", "---\ntype: note\ncreated: 2026-06-01T08:00:00Z\nmentions: 9\n---\n\n# Old\n\nbody only\n")
    try put("Notes/broken.md", "---\nmentions: abc\n# ### ·\n## Log\n### nonsense · [[\n> x\n")
    let from = c.date(from: DateComponents(year: 2026, month: 11, day: 9))!
    let to = c.date(from: DateComponents(year: 2026, month: 11, day: 16))!
    let d = ReviewDigest.build(root: root, from: from, to: to, calendar: c, today: c.date(from: DateComponents(year: 2026, month: 11, day: 12))!)
    check(d.dumps == 3, "digest dumps, got \(d.dumps)")
    check(d.words == 5 + 2 + 2, "digest words, got \(d.words)")
    check(d.daysJournaled == 2, "digest days journaled")
    check(d.streak == 2, "digest streak, got \(d.streak)")
    check(d.topics.count == 1 && d.topics[0].title == "Brain Dump app", "digest topics in period")
    if let t = d.topics.first {
        check(t.entriesInPeriod == 2 && t.totalMentions == 2, "topic counts")
        check(t.quotes.map(\.text) == ["Hello there second line", "One two"], "quotes newest first, multi-line joined")
        check(t.quotes[0].journalLink == "Journal/2026-11-11#07:00", "quote journal link")
        check(t.openTasks == ["Ship review"], "open tasks only")
        check(t.isNew, "new this period")
    }
    check(d.actions.map(\.kind) == ["Event", "To-do", "Note added to"], "actions newest day first, got \(d.actions.map(\.kind))")
    check(d.actions.last?.text == "Brain Dump app" && d.actions.count == 3, "actions exclude other weeks")
    check(d.quiet.map(\.title) == ["Gym"], "quiet topics, got \(d.quiet.map(\.title))")
    let empty = ReviewDigest.build(root: root, from: c.date(from: DateComponents(year: 2027, month: 1, day: 4))!, to: c.date(from: DateComponents(year: 2027, month: 1, day: 11))!, calendar: c)
    check(empty.dumps == 0 && empty.topics.isEmpty && empty.actions.isEmpty, "empty week digest")
    check(ReviewDigest.build(root: root.appendingPathComponent("nope"), from: from, to: to, calendar: c).dumps == 0, "missing root digest")
}

print("\(total) checks, \(failed) failed")
exit(failed == 0 ? 0 : 1)
