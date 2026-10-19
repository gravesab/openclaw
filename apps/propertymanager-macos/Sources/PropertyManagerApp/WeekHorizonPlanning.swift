import Foundation

/// One Sunday–Saturday week (exactly 7 days).
struct PlanningWeek: Identifiable, Hashable, Sendable {
    /// Start of Sunday (device calendar).
    let start: Date
    /// Start of the following Sunday (exclusive end).
    let endExclusive: Date

    var id: String { Self.idFormatter.string(from: start) }

    /// Inclusive Saturday as start-of-day for display.
    var endInclusive: Date {
        Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start
    }

    /// `M/d/yyyy to M/d/yyyy` for this single week.
    var label: String {
        "\(Self.displayFormatter.string(from: start)) to \(Self.displayFormatter.string(from: endInclusive))"
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        date >= start && date < endExclusive
    }

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "M/d/yyyy"
        return formatter
    }()
}

/// Two consecutive weeks (exactly 14 days). One picker selection.
struct PlanningTwoWeekBlock: Identifiable, Hashable, Sendable {
    let first: PlanningWeek
    let second: PlanningWeek

    var id: String { first.id }
    var weeks: [PlanningWeek] { [first, second] }

    /// `M/d/yyyy to M/d/yyyy` spanning the full 14-day block.
    var label: String {
        let formatter = Self.displayFormatter
        return "\(formatter.string(from: first.start)) to \(formatter.string(from: second.endInclusive))"
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        date >= first.start && date < second.endExclusive
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "M/d/yyyy"
        return formatter
    }()
}

enum WeekHorizonPlanning {
    /// First day of the planning catalog.
    static let catalogAnchorComponents = DateComponents(year: 2026, month: 10, day: 1)

    /// Build Sunday-start weeks from the week containing 2026-10-01 through `throughYear` (inclusive).
    static func weeks(
        throughYear: Int = Calendar.current.component(.year, from: Date()) + 2,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [PlanningWeek] {
        var cal = calendar
        cal.firstWeekday = 1 // Sunday
        guard let anchor = cal.date(from: catalogAnchorComponents) else { return [] }
        guard let firstSunday = startOfWeek(containing: anchor, calendar: cal) else { return [] }
        guard let lastDay = cal.date(from: DateComponents(year: throughYear, month: 12, day: 31)) else {
            return []
        }

        var result: [PlanningWeek] = []
        var cursor = firstSunday
        while cursor <= lastDay {
            guard let next = cal.date(byAdding: .day, value: 7, to: cursor) else { break }
            result.append(PlanningWeek(start: cursor, endExclusive: next))
            cursor = next
        }
        // Keep `now` available for default-block helpers without forcing callers to pass it twice.
        _ = now
        return result
    }

    /// Pair consecutive weeks into 14-day picker blocks (exactly two weeks / 14 days each).
    /// Week numbering for display can reset each January; blocks themselves are contiguous pairs
    /// from the October 2026 catalog (and restart pairing after a lone trailing week at year end).
    static func twoWeekBlocks(
        throughYear: Int = Calendar.current.component(.year, from: Date()) + 2,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [PlanningTwoWeekBlock] {
        let all = weeks(throughYear: throughYear, calendar: calendar, now: now)
        var cal = calendar
        cal.firstWeekday = 1

        var blocks: [PlanningTwoWeekBlock] = []
        var index = 0
        while index < all.count {
            let a = all[index]
            let yearA = cal.component(.year, from: a.start)
            // Start a new pairing sequence on the first week of each January.
            if index + 1 >= all.count { break }
            let b = all[index + 1]
            let yearB = cal.component(.year, from: b.start)
            if yearB > yearA {
                // Do not span January with a 14-day block; advance to the January week.
                index += 1
                continue
            }
            blocks.append(PlanningTwoWeekBlock(first: a, second: b))
            index += 2
        }
        return blocks
    }

    static func defaultBlock(
        in blocks: [PlanningTwoWeekBlock],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PlanningTwoWeekBlock? {
        if let hit = blocks.first(where: { $0.contains(now, calendar: calendar) }) {
            return hit
        }
        // Prefer the next upcoming block, else the last past block.
        if let upcoming = blocks.first(where: { $0.first.start > now }) {
            return upcoming
        }
        return blocks.last
    }

    static func startOfWeek(containing date: Date, calendar: Calendar) -> Date? {
        var cal = calendar
        cal.firstWeekday = 1
        let startOfDay = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: startOfDay) // 1 = Sunday
        let delta = weekday - cal.firstWeekday
        return cal.date(byAdding: .day, value: -delta, to: startOfDay)
    }
}

/// Buckets tasks for one selected 2-week block.
struct WeekHorizonBucket<Task>: Sendable where Task: Sendable {
    var overdue: [Task]
    /// Exactly two week sections for the selected block (may be empty lists).
    var weeks: [(week: PlanningWeek, tasks: [Task])]
}

enum WeekHorizonBucketing {
    struct TaskFacts {
        var nextDue: Date
        var scheduleKind: String
        var isActive: Bool
        var isWorkRequest: Bool
        var dueMeter: Bool
        var overdueMeter: Bool
    }

    static func bucket<Task>(
        tasks: [Task],
        block: PlanningTwoWeekBlock,
        now: Date = Date(),
        calendar: Calendar = .current,
        facts: (Task) -> TaskFacts
    ) -> WeekHorizonBucket<Task> {
        let startOfToday = calendar.startOfDay(for: now)
        var overdue: [Task] = []
        var weekA: [Task] = []
        var weekB: [Task] = []

        for task in tasks {
            let fact = facts(task)
            guard fact.isActive, !fact.isWorkRequest else { continue }

            let kind = fact.scheduleKind.lowercased()
            let meterDue = fact.dueMeter || fact.overdueMeter
            if kind == "meter", !meterDue { continue }

            let dueDay = calendar.startOfDay(for: fact.nextDue)
            if meterDue || dueDay < startOfToday {
                overdue.append(task)
                continue
            }
            if block.first.contains(fact.nextDue, calendar: calendar) {
                weekA.append(task)
            } else if block.second.contains(fact.nextDue, calendar: calendar) {
                weekB.append(task)
            }
        }

        func byDue(_ lhs: Task, _ rhs: Task) -> Bool {
            facts(lhs).nextDue < facts(rhs).nextDue
        }
        overdue.sort(by: byDue)
        weekA.sort(by: byDue)
        weekB.sort(by: byDue)

        return WeekHorizonBucket(
            overdue: overdue,
            weeks: [
                (block.first, weekA),
                (block.second, weekB),
            ]
        )
    }
}
