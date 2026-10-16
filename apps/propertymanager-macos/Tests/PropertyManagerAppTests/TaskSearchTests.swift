import XCTest
@testable import PropertyManagerApp

final class TaskSearchTests: XCTestCase {
    private let knifeTasks = [
        ["DR Chipper", "DR Chipper: Check Knife and Wear Plate for Tightness, Nicks, Wear, and Proper Gap"],
        ["DR Chipper", "DR Chipper: Replace or sharpen chipper knife"],
        ["DR Chipper", "DR Chipper: Service wear plate and set knife gap"],
    ]

    func testWordMatchesAnywhereInTheTaskNotOnlyAtTheStart() {
        let words = TaskSearch.words(in: "knife")
        XCTAssertEqual(knifeTasks.filter { TaskSearch.matches(fields: $0, words: words) }.count, 3)
        XCTAssertFalse(TaskSearch.matches(fields: ["DR Chipper", "DR Chipper: Replace drive belt"], words: words))
    }

    func testEveryWordMustMatchInAnyOrderAcrossFields() {
        let words = TaskSearch.words(in: "  KNIFE   chipper ")
        XCTAssertEqual(words, ["KNIFE", "chipper"])
        XCTAssertEqual(knifeTasks.filter { TaskSearch.matches(fields: $0, words: words) }.count, 3)
        XCTAssertEqual(
            knifeTasks.filter { TaskSearch.matches(fields: $0, words: TaskSearch.words(in: "knife gap")) }.count,
            2
        )
    }

    func testBlankSearchShowsEverything() {
        XCTAssertTrue(TaskSearch.matches(fields: ["anything"], words: TaskSearch.words(in: "   ")))
    }
}
