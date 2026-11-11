import Foundation

public struct DateResolver: Sendable {
    public let now: Date
    public let calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// Resolves a phrase such as "tomorrow at 3" or "by Friday" to a future date, or nil.
    public func resolve(_ phrase: String) -> ResolvedDate? {
        var tokens = DateToken.tokenize(phrase)
        guard !tokens.isEmpty else { return nil }
        tokens[0].breakBefore = false
        let parser = DateParser(tokens: tokens, now: now, calendar: calendar, scan: false)
        guard let expr = parser.parseExpr(), expr.end == tokens.count else { return nil }
        return parser.evaluate(expr)
    }

    /// Finds the first future date expression in free text, with the phrase that matched.
    public func firstDate(in text: String) -> (resolved: ResolvedDate, phrase: String)? {
        let tokens = DateToken.tokenize(text)
        var i = 0
        while i < tokens.count {
            var slice = Array(tokens[i...])
            slice[0].breakBefore = false
            let parser = DateParser(tokens: slice, now: now, calendar: calendar, scan: true)
            if let expr = parser.parseExpr() {
                if let resolved = parser.evaluate(expr) {
                    let range = tokens[i + expr.first].range.lowerBound..<tokens[i + expr.end - 1].range.upperBound
                    return (resolved, String(text[range]))
                }
                i += max(expr.end, 1)
            } else {
                i += 1
            }
        }
        return nil
    }
}

// MARK: - Tokens

struct DateToken {
    var text: String
    var range: Range<String.Index>
    /// A sentence boundary sits between this token and the previous one.
    var breakBefore: Bool

    static let abbreviations: Set<String> = [
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    ]

    static func tokenize(_ s: String) -> [DateToken] {
        var tokens: [DateToken] = []
        var i = s.startIndex
        var prevEnd: String.Index?
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while i < s.endIndex {
            guard isWord(s[i]) else { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex {
                let ch = s[j]
                if isWord(ch) { j = s.index(after: j); continue }
                let after = s.index(after: j)
                if after < s.endIndex, j > i {
                    let prev = s[s.index(before: j)]
                    let next = s[after]
                    if (ch == "'" || ch == "\u{2019}"), prev.isLetter, next.isLetter { j = after; continue }
                    if ch == ":", prev.isNumber, next.isNumber { j = after; continue }
                }
                break
            }
            let range = i..<j
            let text = s[range].lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            var brk = false
            var merged = false
            if let pe = prevEnd {
                let gap = s[pe..<i]
                if text == "m", gap == ".", let last = tokens.last, last.text == "a" || last.text == "p" {
                    tokens[tokens.count - 1] = DateToken(
                        text: last.text + "m", range: last.range.lowerBound..<j, breakBefore: last.breakBefore)
                    merged = true
                } else {
                    let hard = gap.contains { "!?;\n".contains($0) }
                    let dot = gap.contains(".") && !abbreviations.contains(tokens.last?.text ?? "")
                    brk = hard || dot
                }
            }
            if !merged { tokens.append(DateToken(text: text, range: range, breakBefore: brk)) }
            prevEnd = j
            i = j
        }
        return tokens
    }
}

// MARK: - Parser

private struct Clock { var h: Int; var m: Int }

private struct Day {
    /// Start of the day, or the exact moment when `exact`.
    var date: Date
    var past = false
    var defaultTime: Clock?
    var exact = false
}

struct DateExpr {
    fileprivate var first: Int
    fileprivate(set) var end: Int
    fileprivate var day: Day?
    fileprivate var time: Clock?
}

private struct NumTok { var n: Int; var minute: Int?; var suffix: String }

private let weekdays: [String: Int] = [
    "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
]

private let months: [String: Int] = [
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
    "oct": 10, "nov": 11, "dec": 12,
]

private let numberWords: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
]

private let partsOfDay: [String: Clock] = [
    "morning": Clock(h: 9, m: 0), "afternoon": Clock(h: 14, m: 0), "evening": Clock(h: 18, m: 0),
    "lunch": Clock(h: 12, m: 30), "lunchtime": Clock(h: 12, m: 30),
]

private let leadingFillers: Set<String> = ["by", "on", "before", "until", "till", "around", "about", "sometime"]

struct DateParser {
    fileprivate let tokens: [DateToken]
    let now: Date
    let calendar: Calendar
    /// Scanning free text, where ambiguous words need a qualifier; false for a whole phrase.
    let scan: Bool

    private var today: Date { calendar.startOfDay(for: now) }

    private func at(_ k: Int) -> String? {
        k < tokens.count && (k == 0 || !tokens[k].breakBefore) ? tokens[k].text : nil
    }

    private func addDays(_ n: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: date) ?? date
    }

    private func set(_ c: Clock, on day: Date) -> Date {
        calendar.date(bySettingHour: c.h, minute: c.m, second: 0, of: day) ?? day
    }

    private func num(_ t: String?) -> NumTok? {
        guard let t else { return nil }
        let chars = Array(t)
        var i = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
        guard i > 0, i <= 4, let n = Int(String(chars[0..<i])) else { return nil }
        var minute: Int?
        if i < chars.count, chars[i] == ":" {
            let start = i + 1
            var j = start
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            guard j - start == 2, let m = Int(String(chars[start..<j])) else { return nil }
            minute = m
            i = j
        }
        let suffix = String(chars[i...])
        guard suffix.allSatisfy({ $0.isLetter }) else { return nil }
        return NumTok(n: n, minute: minute, suffix: suffix)
    }

    private func isOrdinal(_ t: String) -> Bool {
        guard let nt = num(t), nt.minute == nil else { return false }
        return ["st", "nd", "rd", "th"].contains(nt.suffix)
    }

    private func resolveHour(_ n: Int, _ ampm: String?) -> Int {
        if let ampm {
            if ampm == "pm" { return n == 12 ? 12 : n + 12 }
            return n == 12 ? 0 : n
        }
        switch n {
        case 1...7: return n + 12
        default: return n
        }
    }

    // MARK: Expression

    func parseExpr() -> DateExpr? {
        var j = 0
        var qual = false
        while let t = at(j) {
            if leadingFillers.contains(t) {
                j += 1
                qual = true
            } else if t == "this", at(j + 1) == "coming" {
                j += 2
                qual = true
            } else {
                break
            }
        }
        guard at(j) != nil else { return nil }
        var e = DateExpr(first: j, end: j)
        if let (d, n) = parseDay(j, qual) {
            e.day = d
            j = n
            if !d.exact, let (c, n2) = parseTime(j, true) {
                e.time = c
                j = n2
            }
        } else if let (c, n) = parseTime(j, qual) {
            e.time = c
            j = n
            var k = j
            var q = false
            if at(k) == "on" {
                k += 1
                q = true
            }
            if let (d, n2) = parseDay(k, q), !d.exact {
                e.day = d
                j = n2
            }
        } else {
            return nil
        }
        e.end = j
        return e
    }

    func evaluate(_ e: DateExpr) -> ResolvedDate? {
        if let d = e.day {
            if d.past { return nil }
            if d.exact { return ResolvedDate(date: d.date, hasTime: true) }
            if let c = e.time ?? d.defaultTime {
                let date = set(c, on: d.date)
                return date > now ? ResolvedDate(date: date, hasTime: true) : nil
            }
            return d.date >= today ? ResolvedDate(date: d.date, hasTime: false) : nil
        }
        if let c = e.time {
            var date = set(c, on: today)
            if date <= now { date = set(c, on: addDays(1, to: today)) }
            return ResolvedDate(date: date, hasTime: true)
        }
        return nil
    }

    // MARK: Days

    private func weekStart() -> Date {
        calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
    }

    private func onOrAfter(weekday: Int) -> Date {
        let current = calendar.component(.weekday, from: today)
        return addDays((weekday - current + 7) % 7, to: today)
    }

    private func nextWeek(weekday: Int) -> Date {
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return addDays(7 + offset, to: weekStart())
    }

    private func saturdayOrToday() -> Date {
        calendar.component(.weekday, from: today) == 1 ? today : onOrAfter(weekday: 7)
    }

    private func pastDay() -> Day { Day(date: addDays(-1, to: today), past: true) }

    private func parseDay(_ j: Int, _ qual: Bool, the: Bool = false) -> (Day, Int)? {
        guard let t = at(j) else { return nil }
        let abbrevOK = qual || !scan
        switch t {
        case "today": return (Day(date: today), j + 1)
        case "tonight": return (Day(date: today, defaultTime: Clock(h: 20, m: 0)), j + 1)
        case "tomorrow": return (Day(date: addDays(1, to: today)), j + 1)
        case "yesterday": return (pastDay(), j + 1)
        case "eod": return (Day(date: today, defaultTime: Clock(h: 17, m: 0)), j + 1)
        case "day":
            if at(j + 1) == "after", at(j + 2) == "tomorrow" { return (Day(date: addDays(2, to: today)), j + 3) }
            if at(j + 1) == "before", at(j + 2) == "yesterday" { return (pastDay(), j + 3) }
            return nil
        case "end":
            guard at(j + 1) == "of" else { return nil }
            var k = j + 2
            if at(k) == "the" { k += 1 }
            if at(k) == "day" { return (Day(date: today, defaultTime: Clock(h: 17, m: 0)), k + 1) }
            if at(k) == "week" { return (Day(date: onOrAfter(weekday: 6)), k + 1) }
            return nil
        case "weekend":
            return the ? (Day(date: saturdayOrToday()), j + 1) : nil
        case "the":
            guard let n = at(j + 1), ["weekend", "day", "end"].contains(n) || isOrdinal(n) else { return nil }
            return parseDay(j + 1, qual, the: true)
        case "this", "coming", "next", "last":
            return parseModified(t, j)
        case "in":
            return parseRelative(j)
        default:
            break
        }
        if let wd = weekdays[t] {
            if DateToken.abbreviations.contains(t), !abbrevOK { return nil }
            return (Day(date: onOrAfter(weekday: wd)), j + 1)
        }
        if let m = months[t] { return parseMonthFirst(m, j) }
        return parseNumeric(j, the: the)
    }

    private func parseModified(_ mod: String, _ j: Int) -> (Day, Int)? {
        guard let n = at(j + 1) else { return nil }
        if let wd = weekdays[n] {
            switch mod {
            case "next": return (Day(date: nextWeek(weekday: wd)), j + 2)
            case "last": return (pastDay(), j + 2)
            default: return (Day(date: onOrAfter(weekday: wd)), j + 2)
            }
        }
        switch (mod, n) {
        case ("this", "weekend"), ("coming", "weekend"): return (Day(date: saturdayOrToday()), j + 2)
        case ("next", "weekend"): return (Day(date: nextWeek(weekday: 7)), j + 2)
        case ("next", "week"): return (Day(date: addDays(7, to: weekStart())), j + 2)
        case ("last", "week"), ("last", "weekend"), ("last", "night"), ("last", "month"), ("last", "year"):
            return (pastDay(), j + 2)
        case ("this", _):
            if let c = partsOfDay[n] { return (Day(date: today, defaultTime: c), j + 2) }
            return nil
        default: return nil
        }
    }

    private func parseRelative(_ j: Int) -> (Day, Int)? {
        var k = j + 1
        let n: Int
        if at(k) == "half", at(k + 1) == "an", at(k + 2) == "hour" {
            return (Day(date: now.addingTimeInterval(1800), exact: true), k + 3)
        }
        if at(k) == "a" || at(k) == "an" {
            k += 1
            if at(k) == "couple", at(k + 1) == "of" {
                n = 2
                k += 2
            } else {
                n = 1
            }
        } else if at(k) == "couple", at(k + 1) == "of" {
            n = 2
            k += 2
        } else if let nt = num(at(k)), nt.minute == nil, nt.suffix.isEmpty {
            n = nt.n
            k += 1
        } else if let w = at(k), let v = numberWords[w] {
            n = v
            k += 1
        } else {
            return nil
        }
        guard let unit = at(k) else { return nil }
        switch unit {
        case "minute", "minutes", "min", "mins":
            return (Day(date: now.addingTimeInterval(Double(n) * 60), exact: true), k + 1)
        case "hour", "hours", "hr", "hrs":
            return (Day(date: now.addingTimeInterval(Double(n) * 3600), exact: true), k + 1)
        case "day", "days":
            return (Day(date: addDays(n, to: today)), k + 1)
        case "week", "weeks":
            return (Day(date: addDays(7 * n, to: today)), k + 1)
        default:
            return nil
        }
    }

    private func validDate(year: Int, month: Int, day: Int) -> Date? {
        guard let d = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.component(.month, from: d) == month, calendar.component(.day, from: d) == day
        else { return nil }
        return d
    }

    private func monthDay(_ month: Int, _ day: Int, after k: Int) -> (Day, Int)? {
        guard (1...31).contains(day) else { return nil }
        let thisYear = calendar.component(.year, from: today)
        if let y = num(at(k)), y.minute == nil, y.suffix.isEmpty, (2000...2100).contains(y.n) {
            guard let d = validDate(year: y.n, month: month, day: day) else { return nil }
            return (Day(date: d, past: d < today), k + 1)
        }
        for year in thisYear...(thisYear + 8) {
            if let d = validDate(year: year, month: month, day: day), d >= today { return (Day(date: d), k) }
        }
        return nil
    }

    private func parseMonthFirst(_ month: Int, _ j: Int) -> (Day, Int)? {
        var k = j + 1
        if at(k) == "the" { k += 1 }
        guard let nt = num(at(k)), nt.minute == nil, nt.suffix.isEmpty || isOrdinal(at(k) ?? "") else { return nil }
        return monthDay(month, nt.n, after: k + 1)
    }

    private func parseNumeric(_ j: Int, the: Bool) -> (Day, Int)? {
        guard let t = at(j), let nt = num(t), nt.minute == nil else { return nil }
        let ordinal = isOrdinal(t)
        guard nt.suffix.isEmpty || ordinal, (1...31).contains(nt.n) else { return nil }
        var k = j + 1
        if at(k) == "of" { k += 1 }
        if let w = at(k), let m = months[w] { return monthDay(m, nt.n, after: k + 1) }
        guard ordinal, the || !scan else { return nil }
        let year = calendar.component(.year, from: today)
        let month = calendar.component(.month, from: today)
        for offset in 0...14 {
            let total = month - 1 + offset
            if let d = validDate(year: year + total / 12, month: total % 12 + 1, day: nt.n), d >= today {
                return (Day(date: d), j + 1)
            }
        }
        return nil
    }

    // MARK: Times

    private func parseTime(_ j0: Int, _ qual: Bool) -> (Clock, Int)? {
        var j = j0
        var q = qual
        var hadAt = false
        if at(j) == "at" {
            j += 1
            q = true
            hadAt = true
        } else if at(j) == "in", at(j + 1) == "the", let w = at(j + 2), partsOfDay[w] != nil {
            j += 2
            q = true
        }
        guard let t = at(j) else { return nil }
        switch t {
        case "noon", "midday": return (Clock(h: 12, m: 0), j + 1)
        case "midnight": return (Clock(h: 0, m: 0), j + 1)
        case "half", "quarter":
            let to = t == "quarter" && at(j + 1) == "to"
            guard at(j + 1) == "past" || to, let (h, ampm, n) = hourToken(j + 2) else { return nil }
            let hour = resolveHour(h, ampm)
            let minute = t == "half" ? 30 : 15
            return to ? (Clock(h: (hour + 23) % 24, m: 45), n) : (Clock(h: hour % 24, m: minute), n)
        default:
            break
        }
        if let c = partsOfDay[t] {
            return q || !scan ? (c, j + 1) : nil
        }
        guard var nt = num(t) ?? numberWords[t].map({ NumTok(n: $0, minute: nil, suffix: "") }) else { return nil }
        var k = j + 1
        var ampm: String?
        if nt.suffix == "am" || nt.suffix == "pm" {
            ampm = nt.suffix
        } else if !nt.suffix.isEmpty {
            return nil
        } else if let w = at(k), w == "am" || w == "pm" {
            ampm = w
            k += 1
        }
        var oclock = false
        if ampm == nil, at(k) == "o'clock" {
            oclock = true
            k += 1
        }
        nt.suffix = ""
        let minute = nt.minute ?? 0
        guard minute < 60 else { return nil }
        if let ampm {
            guard (1...12).contains(nt.n) else { return nil }
            return (Clock(h: resolveHour(nt.n, ampm), m: minute), k)
        }
        if nt.minute != nil {
            guard nt.n <= 23 else { return nil }
            return (Clock(h: resolveHour(nt.n, nil), m: minute), k)
        }
        guard hadAt || oclock, (1...23).contains(nt.n) else { return nil }
        return (Clock(h: resolveHour(nt.n, nil), m: 0), k)
    }

    private func hourToken(_ j: Int) -> (Int, String?, Int)? {
        guard let t = at(j) else { return nil }
        var nt: NumTok
        if let x = num(t), x.minute == nil {
            nt = x
        } else if let v = numberWords[t] {
            nt = NumTok(n: v, minute: nil, suffix: "")
        } else {
            return nil
        }
        var k = j + 1
        var ampm: String?
        if nt.suffix == "am" || nt.suffix == "pm" {
            ampm = nt.suffix
        } else if !nt.suffix.isEmpty {
            return nil
        } else if let w = at(k), w == "am" || w == "pm" {
            ampm = w
            k += 1
        }
        guard (ampm == nil ? 1...23 : 1...12).contains(nt.n) else { return nil }
        return (nt.n, ampm, k)
    }
}
