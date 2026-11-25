#if os(macOS)
import Foundation

/// One Mac statement wait. Import opens the account's download page in the
/// browser; while the guide sheet is up, this polls Downloads for the CSV the
/// browser just saved. Exactly one new finished CSV files and ingests itself;
/// more than one ends the wait and the person picks through the panel.
/// The watch runs only between start() and stop(), both tied to the guide.
/// Main thread only: the guide starts it there and the timer polls on the
/// main runloop.
final class RanchOSFinanceStatementWatch: @unchecked Sendable {
    struct Snapshot: Equatable {
        let name: String
        let size: Int
        let modified: Date
    }

    /// Browser sidecars. A statement is finished only when none of these
    /// shadows it and its size holds still across two polls.
    static let tempExtensions = ["crdownload", "part", "download", "tmp"]

    static func isTemporary(name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix(".") || lower.hasPrefix("unconfirmed") { return true }
        return tempExtensions.contains((lower as NSString).pathExtension)
    }

    static func isStatement(name: String) -> Bool {
        guard !isTemporary(name: name) else { return false }
        return (name.lowercased() as NSString).pathExtension == "csv"
    }

    /// Temp files shadow the statement they belong to: "stmt.csv.crdownload"
    /// shadows "stmt.csv", "stmt.part" shadows it by stem.
    static func shadowedNames(csvNames: [String], tempNames: [String]) -> Set<String> {
        var bases = Set<String>()
        for temp in tempNames {
            var base = (temp as NSString).deletingPathExtension
            if base.lowercased().hasSuffix(".csv") {
                base = String(base.dropLast(4))
                bases.insert((base + ".csv").lowercased())
            }
            bases.insert(base.lowercased())
        }
        return Set(csvNames.filter { name in
            let stem = (name as NSString).deletingPathExtension.lowercased()
            return bases.contains(name.lowercased()) || bases.contains(stem)
        })
    }

    /// Names, sorted, of new CSVs finished since the wait began. A name the
    /// wait started with counts as new when it was written after the start,
    /// even if the byte size is unchanged. Finished means no temp shadow and
    /// the same size and time as the previous poll: the first poll that sees
    /// a new size or time only records it, and the next poll settles it when
    /// neither changed.
    static func settledStatements(
        current: [Snapshot], previous: [String: Snapshot],
        initial: [String: Snapshot], startedAt: Date
    ) -> [String] {
        let temps = current.filter { isTemporary(name: $0.name) }.map(\.name)
        let csvs = current.filter { isStatement(name: $0.name) }
        let shadowed = shadowedNames(csvNames: csvs.map(\.name), tempNames: temps)
        return csvs.compactMap { snap -> String? in
            if initial[snap.name] != nil {
                guard snap.modified > startedAt else { return nil }
            }
            guard !shadowed.contains(snap.name) else { return nil }
            guard let last = previous[snap.name],
                last.size == snap.size, last.modified == snap.modified
            else { return nil }
            return snap.name
        }.sorted()
    }

    private let directory: URL
    private let startedAt: Date
    private let initial: [String: Snapshot]
    private let onSettled: @Sendable ([URL]) -> Void
    private let onAmbiguous: @Sendable () -> Void
    private var previous: [String: Snapshot]
    private var timer: Timer?
    private var fired = false
    private var stopped = false

    init(
        directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory,
        startedAt: Date = Date(),
        onSettled: @escaping @Sendable ([URL]) -> Void,
        onAmbiguous: @escaping @Sendable () -> Void
    ) {
        self.directory = directory
        self.startedAt = startedAt
        self.onSettled = onSettled
        self.onAmbiguous = onAmbiguous
        let now = Self.snapshot(directory: directory)
        var seed: [String: Snapshot] = [:]
        for snap in now { seed[snap.name] = snap }
        self.initial = seed
        self.previous = seed
    }

    /// Starts the one-second poll. Safe to call once; the guide owns the wait.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Ends the wait. Nothing under observation after this returns.
    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    /// One poll: exactly one settled statement fires once, then the wait ends.
    /// More than one settled statement ends the wait so the person picks.
    /// Zero keeps waiting.
    func poll() {
        guard !fired, !stopped else { return }
        let now = Self.snapshot(directory: directory)
        let settled = Self.settledStatements(
            current: now, previous: previous, initial: initial, startedAt: startedAt)
        previous = Dictionary(uniqueKeysWithValues: now.map { ($0.name, $0) })
        if settled.count > 1 {
            stop()
            onAmbiguous()
            return
        }
        guard settled.count == 1 else { return }
        fired = true
        stop()
        onSettled(settled.map { directory.appendingPathComponent($0) })
    }

    static func snapshot(directory: URL) -> [Snapshot] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }
            return Snapshot(name: url.lastPathComponent, size: size, modified: modified)
        }
    }
}
#endif
