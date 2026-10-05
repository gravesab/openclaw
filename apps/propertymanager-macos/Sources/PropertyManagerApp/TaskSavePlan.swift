import Foundation

/// What an editor save must send so the server only receives the fields the
/// operator changed. `PATCH /tasks/{id}` never rewrites completion history,
/// dates, or parts, so it is preferred; fields outside the server's
/// PATCHABLE_FIELDS are applied onto a freshly fetched copy before the full
/// upsert, which keeps completions recorded on other clients.
struct TaskSavePlan {
    enum FullSaveField: String, CaseIterable {
        case category, kind, priority, frequency, resultNotes, warningDays, criticalDays
        case lastDone, nextDue, sendTelegramUpdate, includeInDailyBriefing, alertIfOverdue
        case isActive, toolsRequired
    }

    var patchFields: [String: Any]
    var partsChanged: Bool
    var fullSaveFields: Set<FullSaveField>

    var isEmpty: Bool { patchFields.isEmpty && !partsChanged && fullSaveFields.isEmpty }

    init(baseline: MaintenanceTask, edited: MaintenanceTask) {
        var patch: [String: Any] = [:]
        func decimal(_ value: Decimal?) -> Any {
            value.map { NSDecimalNumber(decimal: $0).stringValue } ?? NSNull()
        }
        if edited.area != baseline.area { patch["area"] = edited.area }
        if edited.item != baseline.item { patch["item"] = edited.item }
        if edited.estimatedMinutes != baseline.estimatedMinutes { patch["estimated_minutes"] = edited.estimatedMinutes }
        if edited.notes != baseline.notes { patch["notes"] = edited.notes }
        if edited.suppliesNeeded != baseline.suppliesNeeded { patch["supplies_needed"] = edited.suppliesNeeded }
        if edited.taskDescription != baseline.taskDescription { patch["task_description"] = edited.taskDescription }
        if edited.responseInstructions != baseline.responseInstructions {
            patch["response_instructions"] = edited.responseInstructions
        }
        if edited.manufacturer != baseline.manufacturer { patch["manufacturer"] = edited.manufacturer }
        if edited.sourceManualName != baseline.sourceManualName { patch["source_manual_name"] = edited.sourceManualName }
        if edited.origin != baseline.origin { patch["origin"] = edited.origin.rawValue }
        if edited.assetId != baseline.assetId {
            patch["asset_id"] = edited.assetId.map { $0.uuidString.lowercased() } ?? NSNull()
        }
        if edited.scheduleKind != baseline.scheduleKind { patch["schedule_kind"] = edited.scheduleKind }
        if edited.meterIntervalValue != baseline.meterIntervalValue {
            patch["meter_interval_value"] = decimal(edited.meterIntervalValue)
        }
        if edited.meterIntervalUnit != baseline.meterIntervalUnit {
            patch["meter_interval_unit"] = edited.meterIntervalUnit ?? NSNull()
        }
        if edited.nextDueMeterValue != baseline.nextDueMeterValue {
            patch["next_due_meter_value"] = decimal(edited.nextDueMeterValue)
        }
        patchFields = patch
        partsChanged = edited.parts != baseline.parts

        var full = Set<FullSaveField>()
        if edited.category != baseline.category { full.insert(.category) }
        if edited.kind != baseline.kind { full.insert(.kind) }
        if edited.priority != baseline.priority { full.insert(.priority) }
        if edited.frequency != baseline.frequency { full.insert(.frequency) }
        if edited.resultNotes != baseline.resultNotes { full.insert(.resultNotes) }
        if edited.warningDays != baseline.warningDays { full.insert(.warningDays) }
        if edited.criticalDays != baseline.criticalDays { full.insert(.criticalDays) }
        if edited.lastDone != baseline.lastDone { full.insert(.lastDone) }
        if edited.nextDue != baseline.nextDue { full.insert(.nextDue) }
        if edited.sendTelegramUpdate != baseline.sendTelegramUpdate { full.insert(.sendTelegramUpdate) }
        if edited.includeInDailyBriefing != baseline.includeInDailyBriefing { full.insert(.includeInDailyBriefing) }
        if edited.alertIfOverdue != baseline.alertIfOverdue { full.insert(.alertIfOverdue) }
        if edited.isActive != baseline.isActive { full.insert(.isActive) }
        if edited.toolsRequired != baseline.toolsRequired { full.insert(.toolsRequired) }
        fullSaveFields = full
    }

    /// Copies only the operator-changed full-save fields onto the fresh server
    /// copy. The calendar due date is recalculated only when the operator
    /// changed Last Done or the frequency without setting Next Due directly.
    func applyFullSaveFields(from edited: MaintenanceTask, onto fresh: MaintenanceTask) -> MaintenanceTask {
        var merged = fresh
        for field in fullSaveFields {
            switch field {
            case .category: merged.category = edited.category
            case .kind: merged.kind = edited.kind
            case .priority: merged.priority = edited.priority
            case .frequency: merged.frequency = edited.frequency
            case .resultNotes: merged.resultNotes = edited.resultNotes
            case .warningDays: merged.warningDays = edited.warningDays
            case .criticalDays: merged.criticalDays = edited.criticalDays
            case .lastDone: merged.lastDone = edited.lastDone
            case .nextDue: merged.nextDue = edited.nextDue
            case .sendTelegramUpdate: merged.sendTelegramUpdate = edited.sendTelegramUpdate
            case .includeInDailyBriefing: merged.includeInDailyBriefing = edited.includeInDailyBriefing
            case .alertIfOverdue: merged.alertIfOverdue = edited.alertIfOverdue
            case .isActive: merged.isActive = edited.isActive
            case .toolsRequired: merged.toolsRequired = edited.toolsRequired
            }
        }
        let scheduleInputsChanged = fullSaveFields.contains(.lastDone) || fullSaveFields.contains(.frequency)
        if scheduleInputsChanged && !fullSaveFields.contains(.nextDue) {
            merged.recalculateCalendarDueIfApplicable()
        }
        return merged
    }
}
