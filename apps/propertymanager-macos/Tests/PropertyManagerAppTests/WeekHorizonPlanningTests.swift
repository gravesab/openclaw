import XCTest
@testable import PropertyManagerApp

final class WeekHorizonPlanningTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testWeeksAreExactlySevenDaysSundayStart() {
        let weeks = WeekHorizonPlanning.weeks(throughYear: 2026, calendar: calendar, now: date(2026, 10, 19))
        XCTAssertFalse(weeks.isEmpty)
        let first = weeks[0]
        XCTAssertEqual(calendar.component(.weekday, from: first.start), 1)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: first.start, to: first.endExclusive).day,
            7
        )
        XCTAssertEqual(first.start, date(2026, 9, 27))
    }

    func testTwoWeekBlocksAreFourteenDaysAndDoNotSpanJanuary() {
        let blocks = WeekHorizonPlanning.twoWeekBlocks(
            throughYear: 2027,
            calendar: calendar,
            now: date(2026, 10, 19)
        )
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            let days = calendar.dateComponents(
                [.day],
                from: block.first.start,
                to: block.second.endExclusive
            ).day
            XCTAssertEqual(days, 14, block.label)
            let yearFirst = calendar.component(.year, from: block.first.start)
            let yearSecond = calendar.component(.year, from: block.second.start)
            XCTAssertEqual(yearFirst, yearSecond, "block must not span January: \(block.label)")
        }
    }

    func testBucketingOverdueAndWeekSections() {
        let blocks = WeekHorizonPlanning.twoWeekBlocks(
            throughYear: 2026,
            calendar: calendar,
            now: date(2026, 10, 19)
        )
        guard let block = blocks.first(where: { $0.contains(date(2026, 10, 19), calendar: calendar) })
            ?? blocks.first else {
            return XCTFail("expected a block")
        }

        struct Row: Sendable {
            let id: String
            let due: Date
            let kind: String
            let active: Bool
            let work: Bool
            let dueMeter: Bool
        }

        // Mid-week due dates so they are not classified as overdue vs `now`.
        let week1Due = calendar.date(byAdding: .day, value: 3, to: block.first.start)!
        let week2Due = calendar.date(byAdding: .day, value: 3, to: block.second.start)!
        let now = calendar.date(byAdding: .day, value: 1, to: block.first.start)!

        let rows: [Row] = [
            Row(id: "overdue", due: date(2026, 10, 1), kind: "calendar", active: true, work: false, dueMeter: false),
            Row(id: "week1", due: week1Due, kind: "calendar", active: true, work: false, dueMeter: false),
            Row(id: "week2", due: week2Due, kind: "calendar", active: true, work: false, dueMeter: false),
            Row(id: "later", due: date(2026, 12, 1), kind: "calendar", active: true, work: false, dueMeter: false),
            Row(id: "work", due: week1Due, kind: "calendar", active: true, work: true, dueMeter: false),
            Row(id: "meterDue", due: date(2026, 12, 1), kind: "meter", active: true, work: false, dueMeter: true),
        ]

        let bucket = WeekHorizonBucketing.bucket(
            tasks: rows,
            block: block,
            now: now,
            calendar: calendar,
            facts: { row in
                WeekHorizonBucketing.TaskFacts(
                    nextDue: row.due,
                    scheduleKind: row.kind,
                    isActive: row.active,
                    isWorkRequest: row.work,
                    dueMeter: row.dueMeter,
                    overdueMeter: false
                )
            }
        )

        XCTAssertEqual(bucket.overdue.map(\.id), ["overdue", "meterDue"])
        XCTAssertEqual(bucket.weeks[0].tasks.map(\.id), ["week1"])
        XCTAssertEqual(bucket.weeks[1].tasks.map(\.id), ["week2"])
    }
}
