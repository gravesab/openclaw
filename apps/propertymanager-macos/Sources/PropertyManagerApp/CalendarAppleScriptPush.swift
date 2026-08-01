import Foundation

/// Calendar.app AppleScript bridge used when EventKit/calaccessd returns 0 calendars
/// after Full Access (XPC 4099 on ad-hoc Debug builds / macOS betas).
enum CalendarAppleScriptPush {
    static let markerScheme = CalendarSyncService.markerScheme

    static func listCalendarTitles() throws -> [String] {
        let script = """
        with timeout of 15 seconds
        tell application "Calendar"
          set out to {}
          repeat with c in calendars
            set end of out to (name of c as text)
          end repeat
          set AppleScript's text item delimiters to "|||"
          set joined to out as text
          set AppleScript's text item delimiters to ""
          return joined
        end tell
        end timeout
        """
        let joined = try run(script)
        if joined.isEmpty { return [] }
        return joined.components(separatedBy: "|||")
    }

    static func resolveOpenClawTitle(from titles: [String], env: SyncEnv) -> String? {
        let target = CalendarSyncService.calendarTitle(for: env)
        if titles.contains(where: { $0 == target }) { return target }
        if let t = titles.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == target }) {
            return t
        }
        return nil
    }

    static func pushScheduledTasks(
        _ scheduledTasks: [MaintenanceTask],
        startHour: Int,
        startMinute: Int,
        env: SyncEnv,
        assets: [MacRanchAsset]
    ) throws -> Int {
        let titles = try listCalendarTitles()
        NSLog("[CalendarSync] AppleScript calendars (%d): %@", titles.count, titles.joined(separator: " | ") as NSString)
        let expectedCalendarTitle = CalendarSyncService.calendarTitle(for: env)
        guard let calName = resolveOpenClawTitle(from: titles, env: env) else {
            throw CalendarSyncError.calendarNotFound(
                expectedCalendarTitle,
                available: titles,
                authRaw: -1
            )
        }

        // OpenClaw DEV is dedicated to PropertyManager testing, so DEV can
        // safely clear the entire calendar before rebuilding it. Production
        // remains marker-scoped because its calendar may contain other items.
        let cleanupBody: String
        if env == .dev {
            cleanupBody = """
            set removedCount to 0
            try
              set removedCount to count of every event of cal
              delete every event of cal
            end try
            """
        } else {
            cleanupBody = """
            set removedCount to 0
            set d0 to current date
            set year of d0 to 2000
            set month of d0 to January
            set day of d0 to 1
            set hours of d0 to 0
            set minutes of d0 to 0
            set seconds of d0 to 0
            set d1 to current date
            set year of d1 to 2101
            set month of d1 to January
            set day of d1 to 1
            set hours of d1 to 0
            set minutes of d1 to 0
            set seconds of d1 to 0
            set marker to \(asString(markerScheme))
            set envTag to \(asString("env=\(env.rawValue)"))
            set doomed to {}
            set candidates to {}
            try
              set candidates to every event of cal whose start date ≥ d0 and start date < d1
            end try
            repeat with e in candidates
              set n to ""
              try
                set n to description of e as text
              end try
              if n contains marker and n contains envTag then
                set end of doomed to e
              end if
            end repeat
            set removedCount to count of doomed
            repeat with e in doomed
              delete e
            end repeat
            """
        }

        // Idempotent cleanup of all PM-managed events for this environment.
        let deleteScript = """
        with timeout of 60 seconds
        tell application "Calendar"
          set cal to first calendar whose name is \(asString(calName))
          \(cleanupBody)
          return removedCount
        end tell
        end timeout
        """
        _ = try run(deleteScript)

        let cal = Calendar.current
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
            let group = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: assets)
            let taskTitle = TaskTitle.canonicalItem(assetName: group, title: task.item)
            let title = env == .dev ? "[DEV] \(taskTitle)" : taskTitle
            var lines = [CalendarSyncService.marker(taskId: task.id, env: env)]
            if !task.taskDescription.isEmpty { lines.append(task.taskDescription) }
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .none
            lines.append("PropertyManager due date: \(f.string(from: task.nextDue))")
            let notes = lines.joined(separator: "\n")
            let script = """
            set startDate to date \(asString(asDate(cursor)))
            set endDate to date \(asString(asDate(eventEnd)))
            with timeout of 15 seconds
            tell application "Calendar"
              set cal to first calendar whose name is \(asString(calName))
              tell cal
                make new event at end with properties {summary:\(asString(title)), start date:startDate, end date:endDate, description:\(asString(notes))}
              end tell
            end tell
            end timeout
            return "ok"
            """
            _ = try run(script)
            dayCursors[dueDay] = eventEnd
        }
        return scheduledTasks.count
    }

    private static func asString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func asDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy 'at' h:mm:ss a"
        return f.string(from: date)
    }

    @discardableResult
    private static func run(_ source: String) throws -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw CalendarSyncError.appleScriptFailed("Could not create NSAppleScript")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? error.description
            if (error[NSAppleScript.errorNumber] as? Int) == -1712 {
                throw CalendarSyncError.appleScriptFailed(
                    "Calendar did not respond within 15 seconds. Open Calendar once, confirm the OpenClaw calendar exists, then try again."
                )
            }
            throw CalendarSyncError.appleScriptFailed(msg)
        }
        return result.stringValue ?? ""
    }
}
