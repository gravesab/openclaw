import Foundation

/// Same list filters as the iPhone app; To Do is the default view.
enum TaskListFilter: String, CaseIterable, Identifiable {
    case toDo = "To Do"
    case due = "Due"
    case overdue = "Overdue"
    case all = "All"

    var id: String { rawValue }
}

enum TaskDueStatus: Equatable {
    case ok
    case dueSoon
    case overdue
    case critical
}

extension MaintenanceTask {
    func dueStatus(now: Date = Date(), calendar: Calendar = .current) -> TaskDueStatus {
        if nextDue < now {
            let daysPast = calendar.dateComponents([.day], from: nextDue, to: now).day ?? 0
            return daysPast >= criticalDays ? .critical : .overdue
        }
        let daysUntil = calendar.dateComponents([.day], from: now, to: nextDue).day ?? Int.max
        return daysUntil <= warningDays ? .dueSoon : .ok
    }

    /// Due today or past due. Uses the due date rather than `warningDays`:
    /// most warning windows are as long as the interval, so a just-completed
    /// task would otherwise never leave the list.
    func isToDo(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if dueMeter == true || overdueMeter == true { return true }
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
            return true
        }
        return nextDue < endOfToday
    }

    static let schedulingWindowDays = 14

    /// Lists never show work further out than the two-week scheduling window.
    /// Meter-only tasks have no real calendar date, so they show only when the meter says due.
    func isInSchedulingWindow(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if kind == .workRequest { return true }
        if dueMeter == true || overdueMeter == true { return true }
        if scheduleKind == "meter" { return false }
        guard let windowEnd = calendar.date(
            byAdding: .day,
            value: Self.schedulingWindowDays + 1,
            to: calendar.startOfDay(for: now)
        ) else {
            return true
        }
        return nextDue < windowEnd
    }

    func matches(_ filter: TaskListFilter, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isInSchedulingWindow(now: now, calendar: calendar) else { return false }
        switch filter {
        case .toDo:
            return isToDo(now: now, calendar: calendar)
        case .all:
            return true
        case .due:
            return dueStatus(now: now, calendar: calendar) != .ok
        case .overdue:
            switch dueStatus(now: now, calendar: calendar) {
            case .overdue, .critical: return true
            case .ok, .dueSoon: return false
            }
        }
    }
}
