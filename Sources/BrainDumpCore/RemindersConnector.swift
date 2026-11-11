import EventKit
import Foundation

public struct RemindersConnector: Connector {
    public let id = "reminders"
    public let name = "Reminders"
    /// nil uses the user's default Reminders list.
    public let listName: String?

    public init(listName: String? = "Brain Dump") { self.listName = listName }

    private enum Failure: LocalizedError {
        case accessDenied
        case noList(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Brain Dump does not have access to Reminders. Allow it in System Settings > Privacy & Security > Reminders."
            case .noList(let name):
                return "Could not find or create the Reminders list \"\(name)\"."
            }
        }
    }

    /// Asks for Reminders access. Returns false if denied.
    public static func requestAccess() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    public func handles(_ kind: ItemKind) -> Bool { kind.isActionable }

    public func destination(for item: ExtractedItem) -> String { "Reminders › \(listName ?? "Default")" }

    public func execute(_ item: ExtractedItem, context: ActionContext) async throws -> ActionResult {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: break
        case .notDetermined:
            guard (try? await store.requestFullAccessToReminders()) == true else { throw Failure.accessDenied }
        default: throw Failure.accessDenied
        }

        let list = try calendar(in: store)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = item.title
        reminder.notes = (item.quote.isEmpty ? "" : item.quote + "\n") + "— Brain Dump"
        if let due = item.due {
            let cal = Calendar.current
            if item.dueHasTime {
                reminder.dueDateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            } else {
                reminder.dueDateComponents = cal.dateComponents([.year, .month, .day], from: due)
            }
        }
        try store.save(reminder, commit: true)

        var summary = "\(item.kind == .task ? "Task" : "Reminder"): \(item.title)"
        if let due = item.due {
            summary += " — " + Self.describe(due, hasTime: item.dueHasTime, now: context.now)
        }
        return ActionResult(
            itemID: item.id, connectorID: id, summary: summary,
            undoToken: reminder.calendarItemIdentifier,
            openURL: URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    public func undo(_ result: ActionResult) async throws {
        guard let token = result.undoToken else { return }
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw Failure.accessDenied }
        if let reminder = store.calendarItem(withIdentifier: token) as? EKReminder {
            try store.remove(reminder, commit: true)
        }
    }

    /// Short readable date such as "tomorrow 9:00", "Friday" or "20 Nov 15:30".
    public static func describe(_ date: Date, hasTime: Bool, now: Date, calendar: Calendar = .current) -> String {
        func fmt(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = pattern
            return f.string(from: date)
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let day: String
        switch days {
        case 0: day = "today"
        case 1: day = "tomorrow"
        case 2...6: day = fmt("EEEE")
        default: day = fmt("d MMM")
        }
        return hasTime ? "\(day) \(fmt("H:mm"))" : day
    }

    private func calendar(in store: EKEventStore) throws -> EKCalendar {
        guard let listName else {
            guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList("Default") }
            return list
        }
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == listName && $0.allowsContentModifications }) {
            return existing
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = listName
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV })
        else { throw Failure.noList(listName) }
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }
}
