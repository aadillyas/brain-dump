import EventKit
import Foundation

public struct CalendarConnector: Connector {
    public let id = "calendar"
    public let name = "Calendar"
    /// nil uses the user's default calendar for new events.
    public let calendarName: String?

    public init(calendarName: String? = nil) { self.calendarName = calendarName }

    private enum Failure: LocalizedError {
        case accessDenied
        case noCalendar(String)
        case noDate

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Brain Dump does not have access to Calendar. Allow it in System Settings > Privacy & Security > Calendars."
            case .noCalendar(let name):
                return "Could not find or create the calendar \"\(name)\"."
            case .noDate:
                return "No date or time found for this event. Add one, or change it to a To-do."
            }
        }
    }

    /// Asks for Calendar access. Returns false if denied.
    public static func requestAccess() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    public func destination(for item: ExtractedItem, category: ItemCategory) -> String { "Calendar › \(calendarName ?? "Default")" }

    public func execute(_ item: ExtractedItem, context: ActionContext) async throws -> ActionResult {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { throw Failure.accessDenied }
        default: throw Failure.accessDenied
        }

        guard let due = item.due else { throw Failure.noDate }

        let cal = try calendar(in: store)
        let event = EKEvent(eventStore: store)
        event.calendar = cal
        event.title = item.title
        event.notes = (item.quote.isEmpty ? "" : item.quote + "\n") + "— Brain Dump"
        if item.dueHasTime {
            event.startDate = due
            event.endDate = due.addingTimeInterval(30 * 60)
            event.addAlarm(EKAlarm(relativeOffset: -600))
        } else {
            let day = Calendar.current.startOfDay(for: due)
            event.isAllDay = true
            event.startDate = day
            event.endDate = day
        }
        try store.save(event, span: .thisEvent, commit: true)

        let summary = "\(context.category.name): \(item.title) — "
            + RemindersConnector.describe(due, hasTime: item.dueHasTime, now: context.now)
        return ActionResult(
            itemID: item.id, connectorID: id, summary: summary,
            undoToken: event.eventIdentifier,
            openURL: URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    public func undo(_ result: ActionResult) async throws {
        guard let token = result.undoToken else { return }
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw Failure.accessDenied }
        if let event = store.event(withIdentifier: token) {
            try store.remove(event, span: .thisEvent, commit: true)
        }
    }

    private func calendar(in store: EKEventStore) throws -> EKCalendar {
        guard let calendarName else {
            guard let cal = store.defaultCalendarForNewEvents else { throw Failure.noCalendar("Default") }
            return cal
        }
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarName && $0.allowsContentModifications }) {
            return existing
        }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = calendarName
        guard let source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV })
        else { throw Failure.noCalendar(calendarName) }
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal
    }
}
