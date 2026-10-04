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

struct TaskBypassRequest: Identifiable {
    let task: MaintenanceTask
    let action: TaskBypassAction

    var id: UUID { task.id }
}

struct TaskBypassMenu<MenuLabel: View>: View {
    let task: MaintenanceTask
    let onSelect: (TaskBypassAction) -> Void
    @ViewBuilder let label: () -> MenuLabel

    var body: some View {
        Menu {
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
        } label: {
            label()
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

/// One skip or reschedule recorded by the server (`schedule_events` on task detail).
struct TaskScheduleEvent: Identifiable, Codable, Hashable {
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
        previousNextDue = FlexibleDate.decode(c, key: .previousNextDue)
        newNextDue = FlexibleDate.decode(c, key: .newNextDue)
        previousNextDueMeterValue = FlexibleDecimal.decodeDecimal(c, key: .previousNextDueMeterValue)
        newNextDueMeterValue = FlexibleDecimal.decodeDecimal(c, key: .newNextDueMeterValue)
        newDeferredUntil = try c.decodeIfPresent(String.self, forKey: .newDeferredUntil)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        guard let created = FlexibleDate.decode(c, key: .createdAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: c,
                debugDescription: "Invalid schedule event timestamp"
            )
        }
        createdAt = created
    }

    var title: String {
        action == "skip" ? "Skipped" : "Rescheduled"
    }

    var summary: String {
        var parts: [String] = []
        if let held = TaskBypassPolicy.civilDate(newDeferredUntil) {
            parts.append("held until \(held.formatted(date: .abbreviated, time: .omitted))")
        } else if let newNextDue, newNextDue != previousNextDue {
            parts.append("due \(newNextDue.formatted(date: .abbreviated, time: .omitted))")
        }
        if let meter = newNextDueMeterValue, meter != previousNextDueMeterValue {
            parts.append("due at \(NSDecimalNumber(decimal: meter).stringValue) hrs")
        }
        return parts.joined(separator: ", ")
    }
}

enum TaskBypassPolicy {
    /// One-time meter triggers have no next occurrence to skip to.
    static func canSkip(_ task: MaintenanceTask) -> Bool {
        guard task.requiresMeterOnComplete else { return true }
        guard let interval = task.meterIntervalValue else { return false }
        return interval > 0
    }

    static func offersMeterTarget(_ task: MaintenanceTask) -> Bool {
        task.requiresMeterOnComplete
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

    /// The picked day as the server's civil date (`YYYY-MM-DD`), in the device's calendar.
    static func civilDateString(_ date: Date, calendar: Calendar = .current) -> String {
        civilDateFormatter(calendar).string(from: date)
    }

    static func civilDate(_ value: String?, calendar: Calendar = .current) -> Date? {
        guard let value, value.count >= 10 else { return nil }
        return civilDateFormatter(calendar).date(from: String(value.prefix(10)))
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
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["note"] = trimmed }
        return body
    }
}

struct TaskBypassSheet: View {
    @EnvironmentObject private var store: PropertyStore
    @Environment(\.dismiss) private var dismiss

    let task: MaintenanceTask
    var onFinished: () -> Void = {}

    @State private var action: TaskBypassAction
    @State private var target: TaskRescheduleTarget = .date
    @State private var date: Date
    @State private var meterText = ""
    @State private var note = ""
    @State private var localError: String?

    init(task: MaintenanceTask, initialAction: TaskBypassAction = .skip, onFinished: @escaping () -> Void = {}) {
        self.task = task
        self.onFinished = onFinished
        let startOfToday = Calendar.current.startOfDay(for: Date())
        _action = State(initialValue: TaskBypassPolicy.canSkip(task) ? initialAction : .reschedule)
        _date = State(initialValue: max(task.nextDue, startOfToday))
    }

    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }
    private var currentMeter: Decimal? { TaskBypassPolicy.currentMeter(task) }
    private var meterTarget: Decimal? { TaskBypassPolicy.meterTarget(meterText, above: currentMeter) }

    private var canSubmit: Bool {
        guard !store.isBypassing else { return false }
        switch action {
        case .skip:
            return TaskBypassPolicy.canSkip(task)
        case .reschedule:
            return target == .date || meterTarget != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(task.item)
                    LabeledContent("Next due", value: task.nextDue.formatted(date: .abbreviated, time: .omitted))
                    if let trigger = task.nextDueMeterValue {
                        LabeledContent("Due at", value: "\(NSDecimalNumber(decimal: trigger).stringValue) hrs")
                    }
                }

                Section {
                    Picker("Bypass", selection: $action) {
                        ForEach(TaskBypassAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!TaskBypassPolicy.canSkip(task))
                } footer: {
                    Text("Bypassing does not mark the task done. It is recorded in the task's history.")
                }

                switch action {
                case .skip:
                    skipSection
                case .reschedule:
                    rescheduleSection
                }

                Section("Note") {
                    TextField("Why it was bypassed (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let localError {
                    Section("Cannot bypass") {
                        Text(localError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Bypass task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(store.isBypassing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action.label) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    @ViewBuilder
    private var skipSection: some View {
        Section {
            if TaskBypassPolicy.canSkip(task) {
                Label("Moves to the next scheduled date after today, keeping the task's schedule.", systemImage: "forward.end")
                if task.requiresMeterOnComplete {
                    Label("The hour trigger moves up by one interval past the current reading.", systemImage: "gauge.with.dots.needle.67percent")
                }
            } else {
                Text("This is a one-time hour trigger, so there is no next occurrence. Reschedule it instead.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rescheduleSection: some View {
        if TaskBypassPolicy.offersMeterTarget(task) {
            Section {
                Picker("Reschedule by", selection: $target) {
                    ForEach(TaskRescheduleTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        switch target {
        case .date:
            Section {
                DatePicker("New due date", selection: $date, in: startOfToday..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
            } footer: {
                if TaskBypassPolicy.offersMeterTarget(task) {
                    Text("The task stays off To Do until this date, even if the hour trigger is reached.")
                }
            }
        case .meter:
            Section {
                if let currentMeter {
                    LabeledContent("Current reading", value: "\(NSDecimalNumber(decimal: currentMeter).stringValue) hrs")
                }
                TextField("New due at (hours)", text: $meterText)
                    .keyboardType(.decimalPad)
            } footer: {
                Text("Must be above the current reading.")
            }
        }
    }

    @MainActor
    private func submit() async {
        localError = nil
        let succeeded: Bool
        switch action {
        case .skip:
            succeeded = await store.skip(task: task, note: note)
        case .reschedule:
            guard let body = TaskBypassPolicy.reschedulePayload(
                target: target,
                date: date,
                meterValue: meterTarget,
                note: note
            ) else { return }
            succeeded = await store.reschedule(task: task, body: body)
        }
        guard succeeded else {
            localError = store.errorMessage ?? "The task could not be bypassed."
            return
        }
        onFinished()
        dismiss()
    }
}

struct TaskScheduleHistorySection: View {
    let events: [TaskScheduleEvent]

    var body: some View {
        if !events.isEmpty {
            Section("Bypass history") {
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
                }
            }
        }
    }
}
