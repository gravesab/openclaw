import Foundation
import XCTest

/// Mac statement watch. All fixtures synthetic.
final class RanchOSFinanceStatementWatchTests: XCTestCase {
    private let bankCSV = """
    Posted Date,Memo,Amount
    09/02/2026,SUNNY ACRES FEED,-142.07
    09/04/2026,PAYROLL DEPOSIT,2318.44
    """

    // MARK: - Pure decision

    func testNewCSVNeedsTwoStablePolls() {
        let start = Date()
        let snap = RanchOSFinanceStatementWatch.Snapshot(name: "stmt.csv", size: 10, modified: start.addingTimeInterval(1))
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: [snap], previous: [:], initial: [:], startedAt: start),
            [])
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: [snap], previous: ["stmt.csv": snap], initial: [:], startedAt: start),
            ["stmt.csv"])
    }

    func testPreexistingCSVIsIgnoredUnlessWrittenAfterStart() {
        let start = Date()
        let old = RanchOSFinanceStatementWatch.Snapshot(name: "old.csv", size: 10, modified: start.addingTimeInterval(-60))
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: [old], previous: ["old.csv": old],
                initial: ["old.csv": old], startedAt: start),
            [])
        let grown = RanchOSFinanceStatementWatch.Snapshot(name: "old.csv", size: 20, modified: start.addingTimeInterval(1))
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: [grown], previous: ["old.csv": grown],
                initial: ["old.csv": old], startedAt: start),
            ["old.csv"])
        let rewritten = RanchOSFinanceStatementWatch.Snapshot(name: "old.csv", size: 10, modified: start.addingTimeInterval(1))
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: [rewritten], previous: ["old.csv": old],
                initial: ["old.csv": old], startedAt: start),
            [], "the first poll that sees the new time only records it")
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: [rewritten], previous: ["old.csv": rewritten],
                initial: ["old.csv": old], startedAt: start),
            ["old.csv"], "same size but written after the wait started")
    }

    func testTempSidecarsShadowTheirStatement() {
        XCTAssertTrue(RanchOSFinanceStatementWatch.isTemporary(name: "stmt.csv.crdownload"))
        XCTAssertTrue(RanchOSFinanceStatementWatch.isTemporary(name: "stmt.part"))
        XCTAssertFalse(RanchOSFinanceStatementWatch.isStatement(name: "stmt.csv.crdownload"))
        XCTAssertTrue(RanchOSFinanceStatementWatch.isStatement(name: "stmt.csv"))
        let start = Date()
        let csv = RanchOSFinanceStatementWatch.Snapshot(name: "stmt.csv", size: 10, modified: start.addingTimeInterval(1))
        for sidecar in ["stmt.csv.crdownload", "stmt.csv.download", "stmt.part"] {
            let temp = RanchOSFinanceStatementWatch.Snapshot(name: sidecar, size: 4, modified: start.addingTimeInterval(1))
            XCTAssertEqual(
                RanchOSFinanceStatementWatch.settledStatements(
                    current: [csv, temp], previous: ["stmt.csv": csv, sidecar: temp],
                    initial: [:], startedAt: start),
                [], sidecar)
        }
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: [csv], previous: ["stmt.csv": csv], initial: [:], startedAt: start),
            ["stmt.csv"])
    }

    func testNonCSVFilesNeverSettle() {
        let start = Date()
        let current = ["notes.txt", "stmt.pdf", "data.csv.bak"].map {
            RanchOSFinanceStatementWatch.Snapshot(name: $0, size: 10, modified: start.addingTimeInterval(1))
        }
        XCTAssertEqual(
            RanchOSFinanceStatementWatch.settledStatements(
                current: current,
                previous: Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) }),
                initial: [:], startedAt: start),
            [])
    }

    // MARK: - Recognized statements

    func testRecognizedStatements() {
        let card = """
        Transaction Date,Clearing Date,Description,Merchant,Category,Type,Amount (USD),Purchased By
        07/01/2026,07/01/2026,A,Sunny Acres Feed,Feed,purchase,100.00,Sam
        """
        XCTAssertTrue(RanchOSFinanceCSV.isRecognizedStatement(bytes: Data(bankCSV.utf8)))
        XCTAssertTrue(RanchOSFinanceCSV.isRecognizedStatement(bytes: Data(card.utf8)))
        XCTAssertFalse(RanchOSFinanceCSV.isRecognizedStatement(bytes: Data("Foo,Bar,Baz\n1,2,3\n".utf8)))
        XCTAssertFalse(RanchOSFinanceCSV.isRecognizedStatement(bytes: Data()))
        XCTAssertFalse(RanchOSFinanceCSV.isRecognizedStatement(bytes: Data([0xff, 0xd8, 0xff])))
    }

    // MARK: - Poll loop over a temp directory

    func testExactlyOneFiresOnce() throws {
        let directory = try tempDirectory()
        let fired = FiredBox()
        let watch = RanchOSFinanceStatementWatch(directory: directory) { fired.urls.append($0) } onAmbiguous: {
            fired.ambiguous += 1
        }
        try Data(bankCSV.utf8).write(to: directory.appendingPathComponent("stmt.csv"))
        watch.poll()
        XCTAssertTrue(fired.urls.isEmpty)
        watch.poll()
        XCTAssertEqual(fired.urls.count, 1)
        XCTAssertEqual(fired.urls.first?.map(\.lastPathComponent), ["stmt.csv"])
        watch.poll()
        XCTAssertEqual(fired.urls.count, 1)
    }

    func testTwoNewCSVsAskInsteadOfFiring() throws {
        let directory = try tempDirectory()
        let fired = FiredBox()
        let watch = RanchOSFinanceStatementWatch(directory: directory) { fired.urls.append($0) } onAmbiguous: {
            fired.ambiguous += 1
        }
        try Data(bankCSV.utf8).write(to: directory.appendingPathComponent("a.csv"))
        try Data(bankCSV.utf8).write(to: directory.appendingPathComponent("b.csv"))
        watch.poll()
        watch.poll()
        XCTAssertTrue(fired.urls.isEmpty, "neither file files or ingests itself")
        XCTAssertEqual(fired.ambiguous, 1)
        watch.poll()
        XCTAssertEqual(fired.ambiguous, 1, "the wait ended")
    }

    func testRewrittenSameSizeFileFires() throws {
        let directory = try tempDirectory()
        let url = directory.appendingPathComponent("stmt.csv")
        try Data(bankCSV.utf8).write(to: url)
        let start = Date()
        let fired = FiredBox()
        let watch = RanchOSFinanceStatementWatch(directory: directory, startedAt: start) {
            fired.urls.append($0)
        } onAmbiguous: {
            fired.ambiguous += 1
        }
        try FileManager.default.setAttributes(
            [.modificationDate: start.addingTimeInterval(60)], ofItemAtPath: url.path)
        watch.poll()
        XCTAssertTrue(fired.urls.isEmpty, "the first poll only records the new time")
        watch.poll()
        XCTAssertEqual(fired.urls.first?.map(\.lastPathComponent), ["stmt.csv"])
        XCTAssertEqual(fired.ambiguous, 0)
        watch.poll()
        XCTAssertEqual(fired.urls.count, 1, "fires once")
    }

    func testGrowingThenShadowedThenSettled() throws {
        let directory = try tempDirectory()
        let fired = FiredBox()
        let csvURL = directory.appendingPathComponent("stmt.csv")
        let sidecarURL = directory.appendingPathComponent("stmt.csv.crdownload")
        let watch = RanchOSFinanceStatementWatch(directory: directory) { fired.urls.append($0) } onAmbiguous: {
            fired.ambiguous += 1
        }
        try Data("a".utf8).write(to: csvURL)
        try Data("a".utf8).write(to: sidecarURL)
        watch.poll()
        try Data("aa".utf8).write(to: csvURL)
        watch.poll()
        XCTAssertTrue(fired.urls.isEmpty)
        watch.poll()
        XCTAssertTrue(fired.urls.isEmpty, "shadowed by the sidecar")
        try FileManager.default.removeItem(at: sidecarURL)
        watch.poll()
        XCTAssertEqual(fired.urls.count, 1)
    }

    func testStopEndsTheWait() throws {
        let directory = try tempDirectory()
        let fired = FiredBox()
        let watch = RanchOSFinanceStatementWatch(directory: directory) { fired.urls.append($0) } onAmbiguous: {
            fired.ambiguous += 1
        }
        try Data(bankCSV.utf8).write(to: directory.appendingPathComponent("stmt.csv"))
        watch.stop()
        watch.poll()
        watch.poll()
        XCTAssertTrue(fired.urls.isEmpty)
    }

    // MARK: - Filing and ingest parity

    @MainActor
    func testFiredFileIsCopiedAndIngestedOnce() throws {
        let directory = try tempDirectory()
        let folder = directory.appendingPathComponent("Account", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fired = FiredBox()
        let watch = RanchOSFinanceStatementWatch(directory: directory) { fired.urls.append($0) } onAmbiguous: {
            fired.ambiguous += 1
        }
        let original = directory.appendingPathComponent("stmt.csv")
        try Data(bankCSV.utf8).write(to: original)
        watch.poll()
        watch.poll()
        let found = try XCTUnwrap(fired.urls.first?.first)

        let filed = try RanchOSFinanceAccountFolders.file(found, into: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "original stays in Downloads")
        XCTAssertEqual(filed.deletingLastPathComponent().path, folder.path)

        let store = try tempStore()
        let account = try XCTUnwrap(store.createAccount(name: "First Ranch Bank", kind: .bank))
        let bytes = try Data(contentsOf: filed)
        let first = store.ingest(
            fileName: filed.lastPathComponent, bytes: bytes, source: account.name, accountID: account.id)
        XCTAssertEqual(store.charges(fileID: first.file.id).count, 2)
        let second = store.ingest(
            fileName: filed.lastPathComponent, bytes: bytes, source: account.name, accountID: account.id)
        XCTAssertEqual(second.file.id, first.file.id)
        XCTAssertTrue(second.newVendors.isEmpty)
        XCTAssertEqual(store.charges(fileID: first.file.id).count, 2, "rows already kept are skipped")
    }

    // MARK: - Helpers

    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @MainActor
    private func tempStore() throws -> RanchOSFinanceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return RanchOSFinanceStore(
            persistenceURL: directory.appendingPathComponent("ledger.json"),
            suggester: FakeWatchSuggester())
    }
}

private final class FiredBox: @unchecked Sendable {
    var urls: [[URL]] = []
    var ambiguous = 0
}

private final class FakeWatchSuggester: RanchOSFinanceCategorySuggesting, @unchecked Sendable {
    func suggestCategory(vendorName: String, categories: [String]) async -> String? { nil }
}
