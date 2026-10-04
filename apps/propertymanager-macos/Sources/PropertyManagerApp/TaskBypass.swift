import SwiftUI

enum TaskBypassAction: String, CaseIterable, Identifiable {
    case skip
    case reschedule

    var id: String { rawValue }

    var label: String {
        switch self {
        case .skip: return "Skip"
        case .reschedule: return "Reschedule"
        }
    }
}

enum TaskRescheduleTarget: String, CaseIterable, Identifiable {
    case date
    case meter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return "Date"
        case .meter: return "Hours"
        }
    }
}

enum TaskBypassSubmission {
    case skip(note: String?)
    case reschedule(body: [String: Any])
}

struct TaskBypassRequest: Identifiable {
    let task: MaintenanceTask
    let action: TaskBypassAction

    var id: UUID { task.id }
}

/// One skip or reschedule recorded by the server (`schedule_events` on task detail).
struct TaskScheduleEvent: Identifiable, Decodable, Equatable {
    let id: UUID
    var action: String
    var previousNextDue: Date?
    var newNextDue: Date?
    var previousNextDueMeterValue: Decimal?
    var newNextDueMeterValue: Decimal?
    var newDeferredUntil: String?
    var note: String?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, action, note
        case previousNextDue = "previous_next_due"
        case newNextDue = "new_next_due"
        case previousNextDueMeterValue = "previous_next_due_meter_value"
        case newNextDueMeterValue = "new_next_due_meter_value"
        case newDeferredUntil = "new_deferred_until"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        action = try c.decode(String.self, forKey: .action)
        previousNextDue = MacFlexibleDate.decode(c, key: .previousNextDue)
        newNextDue = MacFlexibleDate.decode(c, key: .newNextDue)
        previousNextDueMeterValue = Self.decodeDecimal(c, key: .previousNextDueMeterValue)
        newNextDueMeterValue = Self.decodeDecimal(c, key: .newNextDueMeterValue)
        newDeferredUntil = try c.decodeIfPresent(String.self, forKey: .newDeferredUntil)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        guard let created = MacFlexibleDate.decode(c, key: .createdAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: c,
                debugDescription: "Invalid schedule event timestamp"
            )
        }
        createdAt = created
    }

    private static func decodeDecimal(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> Decimal? {
        if let value = try? c.decodeIfPresent(Decimal.self, forKey: key) { return value }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    var title: String {
        action == "skip" ? "Skipped" : "Rescheduled"
    }

    var summary: String {
        var parts: [String] = []
        if let held = TaskBypassPolicy.civilDay(newDeferredUntil) {
            parts.append("held until \(held)")
        } else if let newNextDue, newNextDue != previousNextDue {
            parts.append("due \(DateHelper.isoDate(newNextDue))")
        }
        if let meter = newNextDueMeterValue, meter != previousNextDueMeterValue {
            parts.append("due at \(NSDecimalNumber(decimal: meter).stringValue) hrs")
        }
        return parts.joined(separator: ", ")
    }
}

enum TaskBypassPolicy {
    static func isMeterScheduled(_ task: MaintenanceTask) -> Bool {
        let kind = task.scheduleKind.lowercased()
        return kind == "meter" || kind == "both"
    }

    /// The server refuses work requests and inactive tasks.
    static func canBypass(_ task: MaintenanceTask) -> Bool {
        task.isActive && task.kind != .workRequest
    }

    /// One-time meter triggers have no next occurrence to skip to.
    static func canSkip(_ task: MaintenanceTask) -> Bool {
        guard canBypass(task) else { return false }
        guard isMeterScheduled(task) else { return true }
        guard let interval = task.meterIntervalValue else { return false }
        return interval > 0
    }

    static func offersMeterTarget(_ task: MaintenanceTask) -> Bool {
        isMeterScheduled(task)
    }

    /// Server-reported reading, derived from the trigger and the hours left.
    static func currentMeter(_ task: MaintenanceTask) -> Decimal? {
        guard let trigger = task.nextDueMeterValue, let remaining = task.remainingMeter else { return nil }
        return trigger - remaining
    }

    static func meterTarget(_ text: String, above current: Decimal?) -> Decimal? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else {
            return nil
        }
        if let current, value <= current { return nil }
        return value
    }

    private static func civilDateFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// The picked day as the server's civil date (`YYYY-MM-DD`), in the Mac's calendar.
    static func civilDateString(_ date: Date, calendar: Calendar = .current) -> String {
        civilDateFormatter(calendar).string(from: date)
    }

    static func civilDate(_ value: String?, calendar: Calendar = .current) -> Date? {
        guard let value, value.count >= 10 else { return nil }
        return civilDateFormatter(calendar).date(from: String(value.prefix(10)))
    }

    /// Server civil date as shown to the operator; no time-zone conversion.
    static func civilDay(_ value: String?) -> String? {
        guard let value, civilDate(value) != nil else { return nil }
        return String(value.prefix(10))
    }

    static func normalizedNote(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func reschedulePayload(
        target: TaskRescheduleTarget,
        date: Date,
        meterValue: Decimal?,
        note: String,
        calendar: Calendar = .current
    ) -> [String: Any]? {
        var body: [String: Any] = [:]
        switch target {
        case .date:
            body["next_due"] = civilDateString(date, calendar: calendar)
        case .meter:
            guard let meterValue else { return nil }
            body["next_due_meter_value"] = NSDecimalNumber(decimal: meterValue).stringValue
        }
        if let trimmed = normalizedNote(note) { body["note"] = trimmed }
        return body
    }
}

struct TaskBypassMenu<MenuLabel: View>: View {
    let task: MaintenanceTask
    let onSelect: (TaskBypassAction) -> Void
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
            TaskBypassMenuItems(task: task, onSelect: onSelect)
        } label: {
            label()
        }
    }
}

struct TaskBypassMenuItems: View {
    let task: MaintenanceTask
    let onSelect: (TaskBypassAction) -> Void

    var body: some View {
        Button {
            onSelect(.skip)
        } label: {
            Label("Skip to Next Due", systemImage: "forward.end")
        }
        .disabled(!TaskBypassPolicy.canSkip(task))
        Button {
            onSelect(.reschedule)
        } label: {
            Label("Reschedule…", systemImage: "calendar.badge.clock")
        }
        .disabled(!TaskBypassPolicy.canBypass(task))
    }
}

struct TaskBypassSheet: View {
    @ObservedObject var store: MaintenanceStore
    let request: TaskBypassRequest
    let onClose: () -> Void

    @State private var action: TaskBypassAction
    @State private var target: TaskRescheduleTarget = .date
    @State private var date: Date
    @State private var meterText = ""
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var localError: String?

    init(store: MaintenanceStore, request: TaskBypassRequest, onClose: @escaping () -> Void) {
        self.store = store
        self.request = request
        self.onClose = onClose
        let startOfToday = Calendar.current.startOfDay(for: Date())
        _action = State(initialValue: TaskBypassPolicy.canSkip(request.task) ? request.action : .reschedule)
        _date = State(initialValue: max(request.task.nextDue, startOfToday))
    }

    private var task: MaintenanceTask { request.task }
    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
    private var currentMeter: Decimal? { TaskBypassPolicy.currentMeter(task) }
    private var meterTarget: Decimal? { TaskBypassPolicy.meterTarget(meterText, above: currentMeter) }

    private var canSubmit: Bool {
        guard !isSubmitting else { return false }
        switch action {
        case .skip:
            return TaskBypassPolicy.canSkip(task)
        case .reschedule:
            return target == .date || meterTarget != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bypass task")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(task.item)
                    .font(.headline)
                Text("Next due: \(DateHelper.isoDate(task.nextDue))")
                    .foregroundStyle(.secondary)
                if let trigger = task.nextDueMeterValue {
                    Text("Due at: \(NSDecimalNumber(decimal: trigger).stringValue) hrs")
                        .foregroundStyle(.secondary)
                }
                Text("Bypassing does not mark the task done. It is recorded in the task's history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Bypass", selection: $action) {
                ForEach(TaskBypassAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!TaskBypassPolicy.canSkip(task))

            switch action {
            case .skip:
                skipSection
            case .reschedule:
                rescheduleSection
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Note (optional)")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $note)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            if let localError {
                Text(localError)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(action.label)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var skipSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if TaskBypassPolicy.canSkip(task) {
                    Label("Moves to the next scheduled date after today, keeping the task's schedule.", systemImage: "forward.end")
                    if TaskBypassPolicy.isMeterScheduled(task) {
                        Label("The hour trigger moves up by one interval past the current reading.", systemImage: "gauge.with.dots.needle.67percent")
                    }
                } else {
                    Text("This is a one-time hour trigger, so there is no next occurrence. Reschedule it instead.")
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var rescheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if TaskBypassPolicy.offersMeterTarget(task) {
                Picker("Reschedule by", selection: $target) {
                    ForEach(TaskRescheduleTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.segmented)
            }
            switch target {
            case .date:
                DatePicker("New due date", selection: $date, in: startOfToday..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .center)
                if TaskBypassPolicy.offersMeterTarget(task) {
                    Text("The task stays off To Do until this date, even if the hour trigger is reached.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .meter:
                if let currentMeter {
                    Text("Current reading: \(NSDecimalNumber(decimal: currentMeter).stringValue) hrs")
                }
                TextField("New due at (hours)", text: $meterText)
                    .textFieldStyle(.roundedBorder)
                Text("Must be above the current reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }
        let submission: TaskBypassSubmission
        switch action {
        case .skip:
            submission = .skip(note: TaskBypassPolicy.normalizedNote(note))
        case .reschedule:
            guard let body = TaskBypassPolicy.reschedulePayload(
                target: target,
                date: date,
                meterValue: meterTarget,
                note: note
            ) else { return }
            submission = .reschedule(body: body)
        }
        isSubmitting = true
        localError = nil
        let failure = await store.bypass(task: task, submission: submission)
        isSubmitting = false
        if let failure {
            localError = failure
            return
        }
        onClose()
    }
}

struct TaskScheduleHistoryList: View {
    let events: [TaskScheduleEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if events.isEmpty {
                Text("No skips or reschedules yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !event.summary.isEmpty {
                            Text(event.summary)
                                .font(.caption)
                        }
                        if let note = event.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
