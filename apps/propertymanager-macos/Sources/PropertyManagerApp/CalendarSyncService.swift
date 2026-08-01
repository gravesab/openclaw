import EventKit
import Foundation

// MARK: - Sync environment

/// Tags every PM-created calendar event as DEV or prod.
/// DEV events carry `env=dev` in their notes marker so the Delete DEV action
/// can remove them all before any prod cutover.  Default while developing on
/// the M4 Development PropertyManagerApp build is `.dev`.
enum SyncEnv: String, CaseIterable, Identifiable {
    case dev
    case prod

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dev: return "DEV"
        case .prod: return "Prod"
        }
    }
}

// MARK: - Calendar sync service

/// One-way publication of PropertyManager task due dates to Apple Calendar.
///
/// ### Marker strategy
/// Every PM-managed event has a stable identifier embedded in its notes field:
///   `propertymanager://task/<uuid>?env=dev`   ← DEV push
///   `propertymanager://task/<uuid>?env=prod`  ← prod push
///
/// Re-publish is fully idempotent: existing PM events in the same environment
/// are removed first, then fresh timed blocks are written. Before a rebuild,
/// the app compares the last successful publication ledger with the managed
/// events that remain. A missing event becomes a pending operator decision;
/// it is never silently treated as completed.
///
/// Each active `calendar` or `both` task is placed on its own `nextDue` date.
/// Tasks sharing a date are stacked from the operator-selected start time.
///
/// ### Calendar authority
/// Apple Calendar is a plan view with one guarded reverse action: deleting a
/// managed event may be confirmed in PropertyManager as task completion. The
/// authenticated REST completion endpoint remains the only state-changing
/// authority. Calendar edits never directly mutate PostgreSQL.
///
/// ### iOS complete
/// The iPhone cannot write EventKit on the Mac directly.  When a task is
/// completed on iPhone, its calendar block is cleaned up on the next Mac
/// push (Push Today) or on next app open, because nextDue will have advanced
/// past today and the task will fall out of the push filter.
final class CalendarSyncService {

    static let shared = CalendarSyncService()

    // Calendar separation is a hard safety boundary.
    // Both calendars must already exist — the service never auto-creates them.
    static let productionCalendarTitle = "OpenClaw"
    static let developmentCalendarTitle = "OpenClaw DEV"

    static func calendarTitle(for env: SyncEnv) -> String {
        env == .dev ? developmentCalendarTitle : productionCalendarTitle
    }

    /// Prefix embedded in every PM event's notes field.
    static let markerScheme = "propertymanager://task/"

    /// Days in each direction searched when bulk-deleting DEV events.
    static let devCleanupWindowDays = 90

    private init() {}

    // MARK: - Marker helpers

    /// Builds the stable notes marker for a task in a given env.
    static func marker(taskId: UUID, env: SyncEnv) -> String {
        "\(markerScheme)\(taskId.uuidString)?env=\(env.rawValue)"
    }

    /// Returns true if the notes string contains a PM marker for `env`.
    static func hasPMMarker(_ notes: String?, env: SyncEnv) -> Bool {
        guard let notes else { return false }
        return notes.contains(markerScheme) && notes.contains("env=\(env.rawValue)")
    }

    /// Returns true if the notes string contains any PM marker (any env).
    static func hasAnyPMMarker(_ notes: String?) -> Bool {
        notes?.contains(markerScheme) ?? false
    }

    /// Extracts the task UUID only when the marker belongs to `env`.
    static func taskID(from notes: String?, env: SyncEnv) -> UUID? {
        guard let notes,
              let markerRange = notes.range(of: markerScheme),
              notes.contains("env=\(env.rawValue)") else { return nil }
        let suffix = notes[markerRange.upperBound...]
        let rawID = suffix.prefix { $0 != "?" && !$0.isWhitespace }
        return UUID(uuidString: String(rawID))
    }

    static func scheduledTaskIDs(_ tasks: [MaintenanceTask]) -> Set<UUID> {
        Set(tasks.compactMap { task in
            guard task.isActive else { return nil }
            let kind = task.scheduleKind.lowercased()
            return (kind == "calendar" || kind == "both") ? task.id : nil
        })
    }

    // MARK: - EventKit access

    /// Requests **full** calendar access (required to resolve the OpenClaw calendar by title).
    /// Write-only access is insufficient: `calendars(for:)` is empty/incomplete under write-only
    /// on macOS 14+/Sequoia+, which surfaced as calendarNotFound even when OpenClaw existed.
    func requestWriteAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return true
        case .writeOnly, .notDetermined:
            // writeOnly must be upgraded — listing calendars by title needs full access.
            return await withCheckedContinuation { cont in
                let s = EKEventStore()
                if #available(macOS 14.0, *) {
                    s.requestFullAccessToEvents { granted, _ in cont.resume(returning: granted) }
                } else {
                    s.requestAccess(to: .event) { granted, _ in cont.resume(returning: granted) }
                }
            }
        default:
            return false
        }
    }

    /// True when EventKit can enumerate calendars (full/legacy authorized).
    private func hasFullCalendarAccess() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    // MARK: - Publish scheduled tasks

    /// Publishes every active calendar-based task on its individual due date.
    ///
    /// Steps:
    /// 1. Request write access.
    /// 2. Find the "OpenClaw" calendar (error if missing).
    /// 3. Remove existing PM events in the same env (idempotent).
    /// 4. Filter tasks: active + calendar|both.
    /// 5. Sort by due date, then high→low priority.
    /// 6. Stack same-day blocks from startHour:startMinute.
    /// 7. Commit.
    ///
    /// Returns the number of events written.
    func pushScheduledTasks(
        _ tasks: [MaintenanceTask],
        startHour: Int,
        startMinute: Int,
        env: SyncEnv,
        assets: [MacRanchAsset]
    ) async throws -> Int {
        let cal = Calendar.current
        let scheduledTasks = tasks
            .filter { task in
                guard task.isActive else { return false }
                let kind = task.scheduleKind.lowercased()
                return kind == "calendar" || kind == "both"
            }
            .sorted { lhs, rhs in
                let leftDay = cal.startOfDay(for: lhs.nextDue)
                let rightDay = cal.startOfDay(for: rhs.nextDue)
                if leftDay != rightDay { return leftDay < rightDay }
                let lp = priorityRank(lhs.priority)
                let rp = priorityRank(rhs.priority)
                if lp != rp { return lp < rp }
                return lhs.item.localizedCaseInsensitiveCompare(rhs.item) == .orderedAscending
            }
        NSLog("[CalendarSync] eligible scheduled tasks=%d (of %d loaded)", scheduledTasks.count, tasks.count)

        // Writes are EventKit-only. Calendar.app AppleScript is intentionally
        // not a write fallback because iCloud can acknowledge deletes before
        // applying them, which previously multiplied task events.
        var ekStore = EKEventStore()
        var calendar: EKCalendar?
        do {
            guard try await requestWriteAccess() else { throw CalendarSyncError.permissionDenied }
            if !hasFullCalendarAccess() { throw CalendarSyncError.fullAccessRequired }
            if ekStore.calendars(for: .event).isEmpty {
                try await Task.sleep(nanoseconds: 400_000_000)
                ekStore = EKEventStore()
            }
            if ekStore.calendars(for: .event).isEmpty {
                throw CalendarSyncError.eventKitWriteUnavailable
            } else {
                calendar = try openClawCalendar(in: ekStore, title: Self.calendarTitle(for: env))
            }
        } catch {
            NSLog("[CalendarSync] EventKit write unavailable (%@)", error.localizedDescription)
            throw error
        }

        guard calendar != nil else { throw CalendarSyncError.eventKitWriteUnavailable }

        let openClaw = calendar!
        var bounds = DateComponents()
        bounds.year = 2000
        bounds.month = 1
        bounds.day = 1
        guard let searchStart = cal.date(from: bounds) else { throw CalendarSyncError.dateArithmetic }
        bounds.year = 2101
        guard let searchEnd = cal.date(from: bounds) else { throw CalendarSyncError.dateArithmetic }
        let pred = ekStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: [openClaw])
        let managedEvents = ekStore.events(matching: pred)
        for ev in managedEvents where Self.hasPMMarker(ev.notes, env: env) {
            try ekStore.remove(ev, span: .thisEvent, commit: false)
        }

        var dayCursors: [Date: Date] = [:]
        for task in scheduledTasks {
            let dueDay = cal.startOfDay(for: task.nextDue)
            var components = cal.dateComponents([.year, .month, .day], from: dueDay)
            components.hour = startHour
            components.minute = startMinute
            components.second = 0
            let cursor = dayCursors[dueDay] ?? cal.date(from: components) ?? dueDay
            let duration = max(1, task.estimatedMinutes)
            let eventEnd = cursor.addingTimeInterval(Double(duration) * 60)

            let ev = EKEvent(eventStore: ekStore)
            let group = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: assets)
            let taskTitle = TaskTitle.canonicalItem(assetName: group, title: task.item)
            ev.title = env == .dev ? "[DEV] \(taskTitle)" : taskTitle
            ev.startDate = cursor
            ev.endDate = eventEnd
            ev.calendar = openClaw

            // Stable PM identifier in notes (env-tagged).
            // Format: propertymanager://task/<uuid>?env=<env>
            var lines = [Self.marker(taskId: task.id, env: env)]
            if !task.taskDescription.isEmpty {
                lines.append(task.taskDescription)
            }
            lines.append("PropertyManager due date: \(shortDate(task.nextDue))")
            ev.notes = lines.joined(separator: "\n")

            try ekStore.save(ev, span: .thisEvent, commit: false)
            dayCursors[dueDay] = eventEnd
        }

        try ekStore.commit()
        return scheduledTasks.count
    }

    // MARK: - Detect operator-deleted managed events

    /// Returns managed task IDs currently present in the environment calendar.
    /// EventKit is preferred; Calendar.app scripting is the same fallback used
    /// by publication when macOS exposes no calendars through EventKit.
    func existingManagedTaskIDs(env: SyncEnv) async throws -> Set<UUID> {
        guard try await requestWriteAccess() else {
            throw CalendarSyncError.permissionDenied
        }

        var ekStore = EKEventStore()
        if ekStore.calendars(for: .event).isEmpty {
            try await Task.sleep(nanoseconds: 400_000_000)
            ekStore = EKEventStore()
        }
        if let calendar = try? openClawCalendar(
            in: ekStore,
            title: Self.calendarTitle(for: env)
        ) {
            let cal = Calendar.current
            var startParts = DateComponents()
            startParts.year = 2000
            startParts.month = 1
            startParts.day = 1
            var endParts = startParts
            endParts.year = 2101
            guard let start = cal.date(from: startParts),
                  let end = cal.date(from: endParts) else {
                throw CalendarSyncError.dateArithmetic
            }
            let predicate = ekStore.predicateForEvents(
                withStart: start,
                end: end,
                calendars: [calendar]
            )
            return Set(ekStore.events(matching: predicate).compactMap {
                Self.taskID(from: $0.notes, env: env)
            })
        }

        return try CalendarAppleScriptPush.existingManagedTaskIDs(env: env)
    }

    // MARK: - Remove one task's events (on complete)

    /// Removes all PM-managed events for `taskId` across the managed date range.
    /// Called immediately when the Mac app completes a task.
    ///
    /// Controlled by the `removeCalendarEventOnComplete` UserDefaults key
    /// (default true) so it can be toggled off with one settings change if
    /// the product preference changes.
    ///
    /// The signed app identity fixes which environment calendar is searched,
    /// so DEV completion cannot remove a production event.
    func removeEventsForTask(taskId: UUID) async throws {
        guard try await requestWriteAccess() else { return }

        let ekStore = EKEventStore()
        guard let calendar = try? openClawCalendar(
            in: ekStore,
            title: Self.calendarTitle(for: AppEnvironment.calendarSyncEnv)
        ) else { return }

        let cal = Calendar.current
        var bounds = DateComponents()
        bounds.year = 2000
        bounds.month = 1
        bounds.day = 1
        guard let searchStart = cal.date(from: bounds) else { return }
        bounds.year = 2101
        guard let searchEnd = cal.date(from: bounds) else { return }

        let pred = ekStore.predicateForEvents(withStart: searchStart, end: searchEnd, calendars: [calendar])
        let events = ekStore.events(matching: pred)
        let target = taskId.uuidString
        var removed = false
        for ev in events where (ev.notes ?? "").contains(target) {
            try ekStore.remove(ev, span: .thisEvent, commit: false)
            removed = true
        }
        if removed { try ekStore.commit() }
    }

    // MARK: - Delete all DEV events

    /// Deletes all PM events tagged `env=dev` in a ±90-day window.
    /// Operates only on the "OpenClaw DEV" calendar. Production events and
    /// the production "OpenClaw" calendar are never touched.
    ///
    /// Returns the count of events deleted.
    func deleteDevEvents() async throws -> Int {
        guard try await requestWriteAccess() else {
            throw CalendarSyncError.permissionDenied
        }
        if !hasFullCalendarAccess() {
            throw CalendarSyncError.fullAccessRequired
        }

        // Fresh store after TCC grant; retry once if calaccessd XPC race returns 0 calendars.
        var ekStore = EKEventStore()
        if ekStore.calendars(for: .event).isEmpty {
            try await Task.sleep(nanoseconds: 400_000_000)
            ekStore = EKEventStore()
        }
        guard let calendar = try? openClawCalendar(in: ekStore, title: Self.developmentCalendarTitle) else {
            throw CalendarSyncError.eventKitWriteUnavailable
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let w = Self.devCleanupWindowDays
        guard
            let start = cal.date(byAdding: .day, value: -w, to: today),
            let end = cal.date(byAdding: .day, value: w + 1, to: today)
        else { throw CalendarSyncError.dateArithmetic }

        let pred = ekStore.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let devEvents = ekStore.events(matching: pred).filter { Self.hasPMMarker($0.notes, env: .dev) }
        for ev in devEvents {
            try ekStore.remove(ev, span: .thisEvent, commit: false)
        }
        if !devEvents.isEmpty { try ekStore.commit() }
        return devEvents.count
    }

    // MARK: - Private helpers

    private func openClawCalendar(in ekStore: EKEventStore, title target: String) throws -> EKCalendar {
        let all = ekStore.calendars(for: .event)
        let auth = EKEventStore.authorizationStatus(for: .event).rawValue
        let titles = all.map { Self.describeCalendar($0) }
        NSLog("[CalendarSync] auth=%d calendars=%d titles=%@", auth, all.count, titles.joined(separator: " | ") as NSString)

        // Prefer exact title match (Andrew-specified "OpenClaw").
        if let cal = all.first(where: { $0.title == target }) {
            return cal
        }
        // Trim edge whitespace (invisible padding in Calendar.app titles).
        if let cal = all.first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == target
        }) {
            return cal
        }
        // Collapse internal whitespace runs, still exact on letters/case.
        let collapsedTarget = Self.collapseWhitespace(target)
        if let cal = all.first(where: {
            Self.collapseWhitespace($0.title) == collapsedTarget
        }) {
            return cal
        }

        let available = all.map(\.title).sorted()
        throw CalendarSyncError.calendarNotFound(target, available: available, authRaw: auth)
    }

    private static func describeCalendar(_ cal: EKCalendar) -> String {
        let src = cal.source?.title ?? "?"
        let hex = cal.title.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ",")
        return "\(cal.title){src=\(src),hex=\(hex),rw=\(cal.allowsContentModifications)}"
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split { $0.isWhitespace }.joined(separator: " ")
    }

    private func priorityRank(_ priority: TaskPriority) -> Int {
        switch priority {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Errors

enum CalendarSyncError: LocalizedError {
    case permissionDenied
    case fullAccessRequired
    case eventKitWriteUnavailable
    case calendarNotFound(String, available: [String], authRaw: Int)
    case dateArithmetic
    case appleScriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar access denied. System Settings → Privacy & Security → Calendars → PropertyManagerApp → Full Access."
        case .fullAccessRequired:
            return "Full Access required (write-only cannot list iCloud calendars). System Settings → Privacy & Security → Calendars → PropertyManagerApp → Full Access, then Push again."
        case .eventKitWriteUnavailable:
            return "Calendar write paused safely: EventKit cannot currently see the iCloud calendars. No AppleScript write fallback was used and no events were changed."
        case .calendarNotFound(let title, let available, let authRaw):
            // Lead with actionable cause so a truncated sidebar still shows the fix.
            if available.isEmpty {
                return "EventKit sees 0 calendars (auth=\(authRaw); 3=full,4=writeOnly). Grant Full Access: System Settings → Privacy & Security → Calendars → PropertyManagerApp. Looking for \"\(title)\"."
            }
            let listed = available.prefix(12).map { "\"\($0)\"" }.joined(separator: ", ")
            let more = available.count > 12 ? " …" : ""
            return "No calendar titled \"\(title)\" (auth=\(authRaw)). EventKit sees: \(listed)\(more)."
        case .dateArithmetic:
            return "Internal error computing calendar date range."
        case .appleScriptFailed(let msg):
            return "Calendar.app scripting failed: \(msg)"
        }
    }
}
