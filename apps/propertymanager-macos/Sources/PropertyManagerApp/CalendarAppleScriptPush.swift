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

        // Calendar/iCloud applies deletion asynchronously. Wait until managed
        // events are actually gone before rebuilding, otherwise rapid launches
        // can multiply the same task event.
        _ = try deleteManagedEvents(env: env)

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
            let exactMarker = CalendarSyncService.marker(taskId: task.id, env: env)
            let script = """
            set startDate to date \(asString(asDate(cursor)))
            set endDate to date \(asString(asDate(eventEnd)))
            with timeout of 15 seconds
            tell application "Calendar"
              set cal to first calendar whose name is \(asString(calName))
              set exactMarker to \(asString(exactMarker))
              set matchingEvents to {}
              repeat with existingEvent in every event of cal
                set existingNotes to ""
                try
                  set existingNotes to description of existingEvent as text
                end try
                if existingNotes contains exactMarker then set end of matchingEvents to existingEvent
              end repeat
              if (count of matchingEvents) is greater than 0 then
                set targetEvent to item 1 of matchingEvents
                set summary of targetEvent to \(asString(title))
                set start date of targetEvent to startDate
                set end date of targetEvent to endDate
                set description of targetEvent to \(asString(notes))
                if (count of matchingEvents) is greater than 1 then
                  repeat with duplicateEvent in items 2 thru -1 of matchingEvents
                    delete duplicateEvent
                  end repeat
                end if
              else
                tell cal
                  make new event at end with properties {summary:\(asString(title)), start date:startDate, end date:endDate, description:\(asString(notes))}
                end tell
              end if
            end tell
            end timeout
            return "ok"
            """
            _ = try run(script)
            dayCursors[dueDay] = eventEnd
        }
        return scheduledTasks.count
    }

    /// Deletes only PropertyManager-managed events for one environment and
    /// waits for Calendar/iCloud to confirm they are gone before returning.
    static func deleteManagedEvents(env: SyncEnv) throws -> Int {
        let titles = try listCalendarTitles()
        let expectedTitle = CalendarSyncService.calendarTitle(for: env)
        guard let calName = resolveOpenClawTitle(from: titles, env: env) else {
            throw CalendarSyncError.calendarNotFound(expectedTitle, available: titles, authRaw: -1)
        }
        let script = """
        with timeout of 60 seconds
        tell application "Calendar"
          set cal to first calendar whose name is \(asString(calName))
          set marker to \(asString(markerScheme))
          set envTag to \(asString("env=\(env.rawValue)"))
          set removedCount to 0
          repeat with cleanupAttempt from 1 to 12
            set doomed to {}
            repeat with existingEvent in every event of cal
              set existingNotes to ""
              try
                set existingNotes to description of existingEvent as text
              end try
              if existingNotes contains marker and existingNotes contains envTag then
                set end of doomed to existingEvent
              end if
            end repeat
            if cleanupAttempt is 1 then set removedCount to count of doomed
            if (count of doomed) is 0 then exit repeat
            repeat with doomedEvent in doomed
              delete doomedEvent
            end repeat
            delay 0.5
          end repeat
          return removedCount
        end tell
        end timeout
        """
        let result = try run(script)
        return Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Reads only PropertyManager markers from the environment calendar.
    /// No events are created, edited, or deleted by this operation.
    static func existingManagedTaskIDs(env: SyncEnv) throws -> Set<UUID> {
        let titles = try listCalendarTitles()
        let expectedTitle = CalendarSyncService.calendarTitle(for: env)
        guard let calName = resolveOpenClawTitle(from: titles, env: env) else {
            throw CalendarSyncError.calendarNotFound(expectedTitle, available: titles, authRaw: -1)
        }
        let script = """
        with timeout of 30 seconds
        tell application "Calendar"
          set cal to first calendar whose name is \(asString(calName))
          set marker to \(asString(markerScheme))
          set envTag to \(asString("env=\(env.rawValue)"))
          set found to {}
          repeat with e in every event of cal
            set n to ""
            try
              set n to description of e as text
            end try
            if n contains marker and n contains envTag then set end of found to n
          end repeat
          set AppleScript's text item delimiters to "|||PM-EVENT|||"
          set joined to found as text
          set AppleScript's text item delimiters to ""
          return joined
        end tell
        end timeout
        """
        let output = try run(script)
        if output.isEmpty { return [] }
        return Set(output.components(separatedBy: "|||PM-EVENT|||").compactMap {
            CalendarSyncService.taskID(from: $0, env: env)
        })
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
