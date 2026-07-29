#!/usr/bin/env python3
"""Patch Mac PropertyManagerApp for run-hours trigger (APITaskDTO + MaintenanceTask).

DEPRECATED for corrections: use apply_run_hours_corrections_patch.py instead.
This older patch shipped silent calendar→meter promote / Double / category gate
behavior that v1.3 corrections supersede.
"""

from __future__ import annotations

import pathlib
import re
import sys

APP_ROOT = pathlib.Path(
    sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "Development/PropertyManagerApp"
)
SWIFT = APP_ROOT / "Sources/PropertyManagerApp/PropertyManagerApp.swift"
API = APP_ROOT / "Sources/PropertyManagerApp/PropertyAPIClient.swift"


def must_replace(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        # Idempotent if target already present
        probe = new.strip().splitlines()[0] if new.strip() else ""
        if probe and probe in text:
            print(f"skip (already): {label}")
            return text
        raise SystemExit(f"missing anchor for {label}")
    print(f"patched: {label}")
    return text.replace(old, new, 1)


def patch_maintenance_task(text: str) -> str:
    text = must_replace(
        text,
        "    var meterIntervalValue: Double? = nil\n"
        "    var meterIntervalUnit: String? = nil\n"
        "    var assetId: UUID? = nil\n",
        "    var meterIntervalValue: Double? = nil\n"
        "    var meterIntervalUnit: String? = nil\n"
        "    var nextDueMeterValue: Double? = nil\n"
        "    var remainingMeter: Double? = nil\n"
        "    var overdueMeter: Bool? = nil\n"
        "    var assetId: UUID? = nil\n",
        "model fields",
    )
    text = must_replace(
        text,
        "        case scheduleKind, meterIntervalValue, meterIntervalUnit, assetId\n",
        "        case scheduleKind, meterIntervalValue, meterIntervalUnit, "
        "nextDueMeterValue, remainingMeter, overdueMeter, assetId\n",
        "coding keys",
    )
    text = must_replace(
        text,
        "        meterIntervalValue: Double? = nil,\n"
        "        meterIntervalUnit: String? = nil,\n"
        "        assetId: UUID? = nil\n"
        "    ) {",
        "        meterIntervalValue: Double? = nil,\n"
        "        meterIntervalUnit: String? = nil,\n"
        "        nextDueMeterValue: Double? = nil,\n"
        "        remainingMeter: Double? = nil,\n"
        "        overdueMeter: Bool? = nil,\n"
        "        assetId: UUID? = nil\n"
        "    ) {",
        "init params",
    )
    text = must_replace(
        text,
        "        self.meterIntervalValue = meterIntervalValue\n"
        "        self.meterIntervalUnit = meterIntervalUnit\n"
        "        self.assetId = assetId\n"
        "    }",
        "        self.meterIntervalValue = meterIntervalValue\n"
        "        self.meterIntervalUnit = meterIntervalUnit\n"
        "        self.nextDueMeterValue = nextDueMeterValue\n"
        "        self.remainingMeter = remainingMeter\n"
        "        self.overdueMeter = overdueMeter\n"
        "        self.assetId = assetId\n"
        "    }",
        "init assigns",
    )

    # Local JSON decoder currently skips meter fields — restore + add trigger fields.
    decoder_tail = (
        "        if parts.isEmpty {\n"
        "            parts = PartRequirement.migrated(fromPartNumbers: partNumbers, urls: referenceURLs)\n"
        "        }\n"
        "    }"
    )
    decoder_new = (
        "        if parts.isEmpty {\n"
        "            parts = PartRequirement.migrated(fromPartNumbers: partNumbers, urls: referenceURLs)\n"
        "        }\n"
        "        scheduleKind = try c.decodeIfPresent(String.self, forKey: .scheduleKind) ?? \"calendar\"\n"
        "        meterIntervalValue = try Self.decodeOptionalDouble(c, forKey: .meterIntervalValue)\n"
        "        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)\n"
        "        nextDueMeterValue = try Self.decodeOptionalDouble(c, forKey: .nextDueMeterValue)\n"
        "        remainingMeter = try Self.decodeOptionalDouble(c, forKey: .remainingMeter)\n"
        "        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)\n"
        "        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)\n"
        "    }"
    )
    if "nextDueMeterValue = try Self.decodeOptionalDouble" not in text:
        text = must_replace(text, decoder_tail, decoder_new, "local decoder meter fields")
    else:
        print("skip (already): local decoder meter fields")

    helpers = """
extension MaintenanceTask {
    fileprivate static func decodeOptionalDouble(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Double? {
        if let v = try c.decodeIfPresent(Double.self, forKey: key) { return v }
        if let i = try c.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        if let s = try c.decodeIfPresent(String.self, forKey: key) {
            return Double(s.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    var showsRunHoursTrigger: Bool {
        if assetId != nil { return true }
        let cat = category.lowercased()
        return cat.contains("equipment") || cat.contains("tractor") || area.lowercased().contains("equipment")
    }

    var runHoursBadge: String? {
        if overdueMeter == true { return "Overdue" }
        if let rem = remainingMeter {
            let remText = rem.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", rem)
                : String(format: "%.1f", rem)
            return "\\(remText) hrs left"
        }
        if let trigger = nextDueMeterValue {
            let t = trigger.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", trigger)
                : String(format: "%.1f", trigger)
            return "Due at \\(t) hrs"
        }
        return nil
    }
}

"""
    if "var showsRunHoursTrigger" not in text:
        if "struct TaskEditorView: View" in text:
            text = text.replace("struct TaskEditorView: View", helpers + "struct TaskEditorView: View", 1)
            print("patched: MaintenanceTask helpers")
        else:
            text += helpers
            print("patched: MaintenanceTask helpers (append)")
    else:
        print("skip (already): MaintenanceTask helpers")

    return text


def patch_editor_and_row(text: str) -> str:
    ui_block = """
                if task.showsRunHoursTrigger {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Run hours trigger (Equipment)")
                            .font(.headline)
                        Text("Task becomes due when this asset's hour meter reaches the trigger.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            LabeledField(title: "Due when meter reaches (hours)") {
                                TextField("e.g. 150", value: $task.nextDueMeterValue, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                                    .onChange(of: task.nextDueMeterValue) { newValue in
                                        if newValue != nil {
                                            task.scheduleKind = "meter"
                                            if task.meterIntervalUnit == nil || task.meterIntervalUnit?.isEmpty == true {
                                                task.meterIntervalUnit = "hrs"
                                            }
                                        }
                                    }
                            }
                            LabeledField(title: "Repeat every (hours)") {
                                TextField("e.g. 50", value: $task.meterIntervalValue, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 160)
                            }
                            Spacer(minLength: 0)
                        }
                        if let badge = task.runHoursBadge {
                            Text(badge)
                                .font(.subheadline)
                                .foregroundStyle(task.overdueMeter == true ? Color.red : Color.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
"""
    if "Due when meter reaches" not in text:
        anchor = """                    Button("Recalculate Next Due") {
                        task.nextDue = Calendar.current.date(byAdding: .day, value: task.warningDays, to: task.lastDone) ?? task.lastDone
                    }
                    .fixedSize()
                    .help("Set Next Due to Last Done plus Warning Days")

                    Spacer(minLength: 0)
                }
            }
        }
    }

    var responseCard: some View {
"""
        if anchor not in text:
            raise SystemExit("missing TaskEditor schedule anchor")
        text = text.replace(
            anchor,
            """                    Button("Recalculate Next Due") {
                        task.nextDue = Calendar.current.date(byAdding: .day, value: task.warningDays, to: task.lastDone) ?? task.lastDone
                    }
                    .fixedSize()
                    .help("Set Next Due to Last Done plus Warning Days")

                    Spacer(minLength: 0)
                }
"""
            + ui_block
            + """
            }
        }
    }

    var responseCard: some View {
""",
            1,
        )
        print("patched: TaskEditor run hours UI")
    else:
        print("skip (already): TaskEditor run hours UI")

    if "task.runHoursBadge" not in text.split("struct TaskRowView", 1)[-1][:3500]:
        old = """                Text(equipmentSubtitle(for: task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
"""
        new = """                Text(equipmentSubtitle(for: task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let badge = task.runHoursBadge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(task.overdueMeter == true ? Color.red : Color.orange)
                }
"""
        if old not in text:
            raise SystemExit("missing TaskRow equipmentSubtitle anchor")
        text = text.replace(old, new, 1)
        print("patched: TaskRow badge")
    else:
        print("skip (already): TaskRow badge")

    return text


API_TASK_DTO = r'''private struct APITaskDTO: Decodable {
    let id: UUID
    let area: String
    let item: String
    let categoryName: String
    let kind: String?
    let priority: String
    let frequency: String
    let taskDescription: String?
    let responseInstructions: String?
    let suppliesNeeded: String?
    let notes: String?
    let resultNotes: String?
    let estimatedMinutes: Int?
    let warningDays: Int
    let criticalDays: Int
    let lastDone: Date
    let nextDue: Date
    let sendTelegramUpdate: Bool?
    let includeInDailyBriefing: Bool?
    let alertIfOverdue: Bool?
    let isActive: Bool?
    let manufacturer: String?
    let sourceManualName: String?
    let origin: String?
    let completionHistory: [String]?
    let toolsRequired: [ToolRequirement]?
    let parts: [APIPartDTO]?
    let photos: [APIPhotoDTO]?
    let scheduleKind: String?
    let meterIntervalValue: Double?
    let meterIntervalUnit: String?
    let nextDueMeterValue: Double?
    let remainingMeter: Double?
    let overdueMeter: Bool?
    let assetId: UUID?

    enum CodingKeys: String, CodingKey {
        case id, area, item, kind, priority, frequency, notes, manufacturer, origin, parts, photos
        case categoryName = "category_name"
        case taskDescription = "task_description"
        case responseInstructions = "response_instructions"
        case suppliesNeeded = "supplies_needed"
        case resultNotes = "result_notes"
        case estimatedMinutes = "estimated_minutes"
        case warningDays = "warning_days"
        case criticalDays = "critical_days"
        case lastDone = "last_done"
        case nextDue = "next_due"
        case sendTelegramUpdate = "send_telegram_update"
        case includeInDailyBriefing = "include_in_daily_briefing"
        case alertIfOverdue = "alert_if_overdue"
        case isActive = "is_active"
        case sourceManualName = "source_manual_name"
        case completionHistory = "completion_history"
        case toolsRequired = "tools_required"
        case scheduleKind = "schedule_kind"
        case meterIntervalValue = "meter_interval_value"
        case meterIntervalUnit = "meter_interval_unit"
        case nextDueMeterValue = "next_due_meter_value"
        case remainingMeter = "remaining_meter"
        case overdueMeter = "overdue_meter"
        case assetId = "asset_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        area = try c.decode(String.self, forKey: .area)
        item = try c.decode(String.self, forKey: .item)
        categoryName = try c.decode(String.self, forKey: .categoryName)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        priority = try c.decode(String.self, forKey: .priority)
        frequency = try c.decode(String.self, forKey: .frequency)
        taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription)
        responseInstructions = try c.decodeIfPresent(String.self, forKey: .responseInstructions)
        suppliesNeeded = try c.decodeIfPresent(String.self, forKey: .suppliesNeeded)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        resultNotes = try c.decodeIfPresent(String.self, forKey: .resultNotes)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        warningDays = try c.decode(Int.self, forKey: .warningDays)
        criticalDays = try c.decode(Int.self, forKey: .criticalDays)
        lastDone = try c.decode(Date.self, forKey: .lastDone)
        nextDue = try c.decode(Date.self, forKey: .nextDue)
        sendTelegramUpdate = try c.decodeIfPresent(Bool.self, forKey: .sendTelegramUpdate)
        includeInDailyBriefing = try c.decodeIfPresent(Bool.self, forKey: .includeInDailyBriefing)
        alertIfOverdue = try c.decodeIfPresent(Bool.self, forKey: .alertIfOverdue)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        sourceManualName = try c.decodeIfPresent(String.self, forKey: .sourceManualName)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        completionHistory = try c.decodeIfPresent([String].self, forKey: .completionHistory)
        toolsRequired = try c.decodeIfPresent([ToolRequirement].self, forKey: .toolsRequired)
        parts = try c.decodeIfPresent([APIPartDTO].self, forKey: .parts)
        photos = try c.decodeIfPresent([APIPhotoDTO].self, forKey: .photos)
        scheduleKind = try c.decodeIfPresent(String.self, forKey: .scheduleKind)
        meterIntervalValue = Self.decodeFlexibleDouble(c, forKey: .meterIntervalValue)
        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)
        nextDueMeterValue = Self.decodeFlexibleDouble(c, forKey: .nextDueMeterValue)
        remainingMeter = Self.decodeFlexibleDouble(c, forKey: .remainingMeter)
        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)
        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)
    }

    private static func decodeFlexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    var asMaintenanceTask: MaintenanceTask {
        let mappedKind = TaskKind(rawValue: kind ?? "") ?? .scheduled
        let mappedPriority = TaskPriority(rawValue: priority) ?? .medium
        let mappedFrequency = TaskFrequency(rawValue: frequency) ?? .monthly
        let mappedOrigin = TaskOrigin(rawValue: origin ?? "")
            ?? ((sourceManualName ?? "").isEmpty ? .owner : .manufacturer)
        let mappedParts = (parts ?? []).map(\.asPartRequirement)
        let photoNames = (photos ?? []).compactMap { photo -> String? in
            let name = photo.fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }

        return MaintenanceTask(
            id: id,
            area: area,
            item: item,
            category: categoryName,
            kind: mappedKind,
            priority: mappedPriority,
            frequency: mappedFrequency,
            taskDescription: taskDescription ?? "",
            responseInstructions: responseInstructions ?? "",
            suppliesNeeded: suppliesNeeded ?? "",
            notes: notes ?? "",
            resultNotes: resultNotes ?? "",
            completionHistory: completionHistory ?? [],
            estimatedMinutes: estimatedMinutes ?? 30,
            warningDays: warningDays,
            criticalDays: criticalDays,
            lastDone: lastDone,
            nextDue: nextDue,
            sendTelegramUpdate: sendTelegramUpdate ?? true,
            includeInDailyBriefing: includeInDailyBriefing ?? true,
            alertIfOverdue: alertIfOverdue ?? true,
            isActive: isActive ?? true,
            manufacturer: manufacturer ?? "",
            sourceManualName: sourceManualName ?? "",
            origin: mappedOrigin,
            partNumbers: mappedParts.map(\.partNumber).filter { !$0.isEmpty },
            referenceURLs: mappedParts.map(\.buyURL).filter { !$0.isEmpty },
            toolsRequired: toolsRequired ?? [],
            parts: mappedParts,
            photoFileNames: photoNames,
            manualImport: nil,
            scheduleKind: scheduleKind ?? "calendar",
            meterIntervalValue: meterIntervalValue,
            meterIntervalUnit: meterIntervalUnit,
            nextDueMeterValue: nextDueMeterValue,
            remainingMeter: remainingMeter,
            overdueMeter: overdueMeter,
            assetId: assetId
        )
    }

    static func payload(from task: MaintenanceTask) -> [String: Any] {
        let iso = ISO8601DateFormatter.full
        let body: [String: Any] = [
            "id": task.id.uuidString,
            "area": task.area,
            "item": task.item,
            "category_name": task.category,
            "kind": task.kind.rawValue,
            "priority": task.priority.rawValue,
            "frequency": task.frequency.rawValue,
            "task_description": task.taskDescription,
            "response_instructions": task.responseInstructions,
            "supplies_needed": task.suppliesNeeded,
            "notes": task.notes,
            "result_notes": task.resultNotes,
            "estimated_minutes": task.estimatedMinutes,
            "warning_days": task.warningDays,
            "critical_days": task.criticalDays,
            "last_done": iso.string(from: task.lastDone),
            "next_due": iso.string(from: task.nextDue),
            "send_telegram_update": task.sendTelegramUpdate,
            "include_in_daily_briefing": task.includeInDailyBriefing,
            "alert_if_overdue": task.alertIfOverdue,
            "is_active": task.isActive,
            "manufacturer": task.manufacturer,
            "source_manual_name": task.sourceManualName,
            "origin": task.origin.rawValue,
            "completion_history": task.completionHistory,
            "tools_required": task.toolsRequired.map { tool -> [String: Any] in
                [
                    "id": tool.id.uuidString,
                    "name": tool.name,
                    "size": tool.size,
                    "notes": tool.notes,
                ]
            },
            "schedule_kind": task.scheduleKind,
            "meter_interval_value": task.meterIntervalValue as Any,
            "meter_interval_unit": task.meterIntervalUnit as Any,
            "next_due_meter_value": task.nextDueMeterValue as Any,
            "asset_id": task.assetId?.uuidString as Any,
            "parts": task.parts.enumerated().map { index, part -> [String: Any] in
                [
                    "id": part.id.uuidString,
                    "name": part.name,
                    "oem_part_number": part.oemPartNumber,
                    "part_number": part.partNumber,
                    "buy_url": part.buyURL,
                    "cost": part.cost,
                    "quantity": 1,
                    "sort_order": index,
                ]
            },
        ]
        return body
    }
}
'''


def patch_api(api: str) -> str:
    if "next_due_meter_value" in api and "decodeFlexibleDouble" in api and "nextDueMeterValue" in api:
        print("skip (already): APITaskDTO run-hours")
        return api
    pattern = re.compile(
        r"private struct APITaskDTO: Decodable \{.*?^    static func payload\(from task: MaintenanceTask\) -> \[String: Any\] \{.*?^\}\n",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(api)
    if not match:
        raise SystemExit("missing APITaskDTO block")
    print("patched: APITaskDTO decode/map/payload")
    return api[: match.start()] + API_TASK_DTO + "\n" + api[match.end() :]


def main() -> None:
    if not SWIFT.is_file() or not API.is_file():
        raise SystemExit(f"missing Swift sources under {APP_ROOT}")

    text = SWIFT.read_text(encoding="utf-8")
    api = API.read_text(encoding="utf-8")

    text = patch_maintenance_task(text)
    text = patch_editor_and_row(text)
    api = patch_api(api)

    SWIFT.write_text(text, encoding="utf-8")
    API.write_text(api, encoding="utf-8")
    print("done", SWIFT)
    print("done", API)


if __name__ == "__main__":
    main()
