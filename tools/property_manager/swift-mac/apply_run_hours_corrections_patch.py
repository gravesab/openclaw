#!/usr/bin/env python3
"""Apply v1.3 run-hours corrections to Mac PropertyManagerApp (supersedes old ship).

Fixes vs prior patch:
- Gate on linked asset meter_type == runtime_hours (not category / any assetId)
- Decimal meter fields (not Double)
- Explicit schedule_kind meter|both; no onChange silent promote
- Deliberate Apply button after valid parse (no partial autosave of trigger)
- Badges: N hrs left / Due now / Overdue
- Preserve manufacturer origin/sourceManualName/manualImport (do not clear on trigger edit)
"""

from __future__ import annotations

import pathlib
import sys

APP_ROOT = pathlib.Path(
    sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "Development/PropertyManagerApp"
)
SWIFT = APP_ROOT / "Sources/PropertyManagerApp/PropertyManagerApp.swift"
API = APP_ROOT / "Sources/PropertyManagerApp/PropertyAPIClient.swift"


def must_replace(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        if new.strip() and new.strip().splitlines()[0] in text:
            print(f"skip (already): {label}")
            return text
        raise SystemExit(f"missing anchor for {label}")
    print(f"patched: {label}")
    return text.replace(old, new, 1)


def patch_model(text: str) -> str:
    text = must_replace(
        text,
        "    var meterIntervalValue: Double? = nil\n"
        "    var meterIntervalUnit: String? = nil\n"
        "    var nextDueMeterValue: Double? = nil\n"
        "    var remainingMeter: Double? = nil\n"
        "    var overdueMeter: Bool? = nil\n"
        "    var assetId: UUID? = nil\n",
        "    var meterIntervalValue: Decimal? = nil\n"
        "    var meterIntervalUnit: String? = nil\n"
        "    var nextDueMeterValue: Decimal? = nil\n"
        "    var remainingMeter: Decimal? = nil\n"
        "    var dueMeter: Bool? = nil\n"
        "    var overdueMeter: Bool? = nil\n"
        "    var assetId: UUID? = nil\n",
        "model Decimal fields",
    )
    text = must_replace(
        text,
        "        case scheduleKind, meterIntervalValue, meterIntervalUnit, "
        "nextDueMeterValue, remainingMeter, overdueMeter, assetId\n",
        "        case scheduleKind, meterIntervalValue, meterIntervalUnit, "
        "nextDueMeterValue, remainingMeter, dueMeter, overdueMeter, assetId\n",
        "coding keys dueMeter",
    )
    text = must_replace(
        text,
        "        meterIntervalValue: Double? = nil,\n"
        "        meterIntervalUnit: String? = nil,\n"
        "        nextDueMeterValue: Double? = nil,\n"
        "        remainingMeter: Double? = nil,\n"
        "        overdueMeter: Bool? = nil,\n"
        "        assetId: UUID? = nil\n"
        "    ) {",
        "        meterIntervalValue: Decimal? = nil,\n"
        "        meterIntervalUnit: String? = nil,\n"
        "        nextDueMeterValue: Decimal? = nil,\n"
        "        remainingMeter: Decimal? = nil,\n"
        "        dueMeter: Bool? = nil,\n"
        "        overdueMeter: Bool? = nil,\n"
        "        assetId: UUID? = nil\n"
        "    ) {",
        "init Decimal params",
    )
    text = must_replace(
        text,
        "        self.nextDueMeterValue = nextDueMeterValue\n"
        "        self.remainingMeter = remainingMeter\n"
        "        self.overdueMeter = overdueMeter\n"
        "        self.assetId = assetId\n"
        "    }",
        "        self.nextDueMeterValue = nextDueMeterValue\n"
        "        self.remainingMeter = remainingMeter\n"
        "        self.dueMeter = dueMeter\n"
        "        self.overdueMeter = overdueMeter\n"
        "        self.assetId = assetId\n"
        "    }",
        "init dueMeter assign",
    )
    text = must_replace(
        text,
        "        nextDueMeterValue = try Self.decodeOptionalDouble(c, forKey: .nextDueMeterValue)\n"
        "        remainingMeter = try Self.decodeOptionalDouble(c, forKey: .remainingMeter)\n"
        "        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)\n"
        "        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)\n",
        "        nextDueMeterValue = try Self.decodeOptionalDecimal(c, forKey: .nextDueMeterValue)\n"
        "        remainingMeter = try Self.decodeOptionalDecimal(c, forKey: .remainingMeter)\n"
        "        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)\n"
        "        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)\n"
        "        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)\n"
        "        meterIntervalValue = try Self.decodeOptionalDecimal(c, forKey: .meterIntervalValue)\n",
        "decoder Decimal+dueMeter",
    )
    # Fix duplicate meterIntervalValue decode if we left the Double line
    text = text.replace(
        "        meterIntervalValue = try Self.decodeOptionalDouble(c, forKey: .meterIntervalValue)\n"
        "        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)\n"
        "        nextDueMeterValue = try Self.decodeOptionalDecimal(c, forKey: .nextDueMeterValue)\n"
        "        remainingMeter = try Self.decodeOptionalDecimal(c, forKey: .remainingMeter)\n"
        "        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)\n"
        "        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)\n"
        "        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)\n"
        "        meterIntervalValue = try Self.decodeOptionalDecimal(c, forKey: .meterIntervalValue)\n",
        "        meterIntervalValue = try Self.decodeOptionalDecimal(c, forKey: .meterIntervalValue)\n"
        "        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)\n"
        "        nextDueMeterValue = try Self.decodeOptionalDecimal(c, forKey: .nextDueMeterValue)\n"
        "        remainingMeter = try Self.decodeOptionalDecimal(c, forKey: .remainingMeter)\n"
        "        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)\n"
        "        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)\n"
        "        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)\n",
    )
    return text


HELPERS_OLD = """    var showsRunHoursTrigger: Bool {
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
"""

HELPERS_NEW = """    fileprivate static func decodeOptionalDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Decimal? {
        if let v = try c.decodeIfPresent(Decimal.self, forKey: key) { return v }
        if let i = try c.decodeIfPresent(Int.self, forKey: key) { return Decimal(i) }
        if let d = try c.decodeIfPresent(Double.self, forKey: key) {
            return Decimal(string: String(d))
        }
        if let s = try c.decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: s.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    /// Controlling rule: linked activated runtime_hours asset (category not authoritative).
    func showsRunHoursTrigger(assets: [MacRanchAsset]) -> Bool {
        guard let assetId,
              let asset = assets.first(where: { $0.id == assetId })
        else { return false }
        return asset.meter?.meterType == "runtime_hours" && asset.meterActivatedAt != nil
    }

    var runHoursBadge: String? {
        if overdueMeter == true { return "Overdue" }
        if dueMeter == true { return "Due now" }
        if let rem = remainingMeter, rem > 0 {
            return "\\(NSDecimalNumber(decimal: rem).stringValue) hrs left"
        }
        if let trigger = nextDueMeterValue {
            return "Due at \\(NSDecimalNumber(decimal: trigger).stringValue) hrs"
        }
        return nil
    }
"""


UI_OLD = """                if task.showsRunHoursTrigger {
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

UI_NEW = """                if task.showsRunHoursTrigger(assets: assets) {
                    RunHoursTriggerEditor(
                        task: $task,
                        assets: assets,
                        onCommit: { autosaveAction(task) }
                    )
                    .padding(.top, 8)
                }
"""


RUN_HOURS_EDITOR = r'''
struct RunHoursTriggerEditor: View {
    @Binding var task: MaintenanceTask
    let assets: [MacRanchAsset]
    let onCommit: () -> Void

    @State private var triggerText: String = ""
    @State private var intervalText: String = ""
    @State private var scheduleChoice: String = "meter"
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run hours trigger")
                .font(.headline)
            Text("Absolute trigger is an operator scheduling decision. Manufacturer interval provenance is preserved on save.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                LabeledField(title: "Due when meter reaches (hours)") {
                    TextField("e.g. 150", text: $triggerText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
                LabeledField(title: "Repeat every (hours, optional)") {
                    TextField("e.g. 50", text: $intervalText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
                Picker("Schedule", selection: $scheduleChoice) {
                    Text("Meter only").tag("meter")
                    Text("Calendar + meter").tag("both")
                }
                .frame(maxWidth: 200)
                Button("Apply trigger") { applyTrigger() }
                    .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.caption)
            }
            if let badge = task.runHoursBadge {
                Text(badge)
                    .font(.subheadline)
                    .foregroundStyle(
                        task.overdueMeter == true ? Color.red
                            : (task.dueMeter == true ? Color.orange : Color.secondary)
                    )
            }
        }
        .onAppear { loadFromTask() }
    }

    private func loadFromTask() {
        triggerText = task.nextDueMeterValue.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        intervalText = task.meterIntervalValue.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        let kind = task.scheduleKind.lowercased()
        if kind == "both" || (kind == "calendar" && task.warningDays > 0) {
            scheduleChoice = "both"
        } else {
            scheduleChoice = kind == "meter" ? "meter" : "both"
        }
    }

    private func applyTrigger() {
        errorText = nil
        guard task.assetId != nil else {
            errorText = "Link a runtime_hours asset first."
            return
        }
        guard task.showsRunHoursTrigger(assets: assets) else {
            errorText = "Linked asset must have activated runtime_hours meter."
            return
        }
        let trimmed = triggerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let trigger = Decimal(string: trimmed.replacingOccurrences(of: ",", with: ".")) else {
            errorText = "Enter a valid trigger (blank is not zero)."
            return
        }
        if trigger < 0 {
            errorText = "Trigger must be nonnegative."
            return
        }
        let intervalTrim = intervalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if intervalTrim.isEmpty {
            task.meterIntervalValue = nil
        } else if let interval = Decimal(string: intervalTrim.replacingOccurrences(of: ",", with: ".")) {
            if interval < 0 {
                errorText = "Interval must be nonnegative."
                return
            }
            task.meterIntervalValue = interval
        } else {
            errorText = "Interval is not a valid number."
            return
        }
        // Explicit schedule_kind only — never silent calendar→meter.
        task.scheduleKind = scheduleChoice
        task.nextDueMeterValue = trigger
        task.meterIntervalUnit = "hrs"
        // Do not touch origin / sourceManualName / manualImport.
        onCommit()
    }
}

'''


def patch_helpers_and_ui(text: str) -> str:
    # Escape for Python string that contains Swift interpolations already escaped
    old = HELPERS_OLD.replace("\\(", "(").replace("\\\\", "\\")
    # The file has real \( not escaped - fix:
    old = """    var showsRunHoursTrigger: Bool {
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
            return "\(remText) hrs left"
        }
        if let trigger = nextDueMeterValue {
            let t = trigger.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", trigger)
                : String(format: "%.1f", trigger)
            return "Due at \(t) hrs"
        }
        return nil
    }
"""
    new = """    fileprivate static func decodeOptionalDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Decimal? {
        if let v = try c.decodeIfPresent(Decimal.self, forKey: key) { return v }
        if let i = try c.decodeIfPresent(Int.self, forKey: key) { return Decimal(i) }
        if let d = try c.decodeIfPresent(Double.self, forKey: key) {
            return Decimal(string: String(d))
        }
        if let s = try c.decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: s.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    /// Controlling rule: linked activated runtime_hours asset (category not authoritative).
    func showsRunHoursTrigger(assets: [MacRanchAsset]) -> Bool {
        guard let assetId,
              let asset = assets.first(where: { $0.id == assetId })
        else { return false }
        return asset.meter?.meterType == "runtime_hours" && asset.meterActivatedAt != nil
    }

    var runHoursBadge: String? {
        if overdueMeter == true { return "Overdue" }
        if dueMeter == true { return "Due now" }
        if let rem = remainingMeter, rem > 0 {
            return "\(NSDecimalNumber(decimal: rem).stringValue) hrs left"
        }
        if let trigger = nextDueMeterValue {
            return "Due at \(NSDecimalNumber(decimal: trigger).stringValue) hrs"
        }
        return nil
    }
"""
    if "func showsRunHoursTrigger(assets:" in text:
        print("skip (already): helpers runtime_hours gate")
    else:
        text = must_replace(text, old, new, "helpers runtime_hours + Decimal")

    if "struct RunHoursTriggerEditor" not in text:
        anchor = "struct TaskEditorView: View {"
        if anchor not in text:
            raise SystemExit("missing TaskEditorView anchor")
        text = text.replace(anchor, RUN_HOURS_EDITOR + "\n" + anchor, 1)
        print("patched: RunHoursTriggerEditor")
    else:
        print("skip (already): RunHoursTriggerEditor")

    ui_old = """                if task.showsRunHoursTrigger {
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
    ui_new = """                if task.showsRunHoursTrigger(assets: assets) {
                    RunHoursTriggerEditor(
                        task: $task,
                        assets: assets,
                        onCommit: { autosaveAction(task) }
                    )
                    .padding(.top, 8)
                }
"""
    if "RunHoursTriggerEditor(" in text and "onChange(of: task.nextDueMeterValue)" not in text:
        print("skip (already): UI deliberate save")
    else:
        text = must_replace(text, ui_old, ui_new, "UI deliberate save")

    # Pass assets into TaskEditorView
    text = must_replace(
        text,
        "            TaskEditorView(\n"
        "                task: $store.tasks[index],\n"
        "                categories: store.categories,\n",
        "            TaskEditorView(\n"
        "                task: $store.tasks[index],\n"
        "                categories: store.categories,\n"
        "                assets: store.assets,\n",
        "TaskEditorView assets arg",
    )
    text = must_replace(
        text,
        "struct TaskEditorView: View {\n"
        "    @Binding var task: MaintenanceTask\n"
        "    let categories: [CategoryDefinition]\n\n"
        "    let autosaveAction:",
        "struct TaskEditorView: View {\n"
        "    @Binding var task: MaintenanceTask\n"
        "    let categories: [CategoryDefinition]\n"
        "    let assets: [MacRanchAsset]\n\n"
        "    let autosaveAction:",
        "TaskEditorView assets property",
    )

    # Badge foreground for due now in TaskRow if present
    text = text.replace(
        ".foregroundStyle(task.overdueMeter == true ? Color.red : Color.orange)",
        ".foregroundStyle(task.overdueMeter == true ? Color.red : (task.dueMeter == true ? Color.orange : Color.secondary))",
    )
    return text


def patch_api(text: str) -> str:
    text = text.replace("let meterIntervalValue: Double?", "let meterIntervalValue: Decimal?")
    text = text.replace("let nextDueMeterValue: Double?", "let nextDueMeterValue: Decimal?")
    text = text.replace("let remainingMeter: Double?", "let remainingMeter: Decimal?")
    if "let dueMeter: Bool?" not in text:
        text = text.replace(
            "let remainingMeter: Decimal?\n    let overdueMeter: Bool?",
            "let remainingMeter: Decimal?\n    let dueMeter: Bool?\n    let overdueMeter: Bool?",
        )
    if 'case dueMeter = "due_meter"' not in text:
        text = text.replace(
            'case remainingMeter = "remaining_meter"\n        case overdueMeter = "overdue_meter"',
            'case remainingMeter = "remaining_meter"\n        case dueMeter = "due_meter"\n        case overdueMeter = "overdue_meter"',
        )
    text = text.replace(
        "nextDueMeterValue = Self.decodeFlexibleDouble(c, forKey: .nextDueMeterValue)",
        "nextDueMeterValue = Self.decodeFlexibleDecimal(c, forKey: .nextDueMeterValue)",
    )
    text = text.replace(
        "remainingMeter = Self.decodeFlexibleDouble(c, forKey: .remainingMeter)",
        "remainingMeter = Self.decodeFlexibleDecimal(c, forKey: .remainingMeter)",
    )
    text = text.replace(
        "meterIntervalValue = Self.decodeFlexibleDouble(c, forKey: .meterIntervalValue)",
        "meterIntervalValue = Self.decodeFlexibleDecimal(c, forKey: .meterIntervalValue)",
    )
    if "dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)" not in text:
        text = text.replace(
            "overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)",
            "dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)\n"
            "        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)",
        )
    if "dueMeter: dueMeter," not in text and "nextDueMeterValue: nextDueMeterValue," in text:
        text = text.replace(
            "nextDueMeterValue: nextDueMeterValue,\n            remainingMeter: remainingMeter,\n            overdueMeter: overdueMeter,",
            "nextDueMeterValue: nextDueMeterValue,\n            remainingMeter: remainingMeter,\n            dueMeter: dueMeter,\n            overdueMeter: overdueMeter,",
        )
    # Serialize Decimal as string for API
    text = text.replace(
        '"next_due_meter_value": task.nextDueMeterValue as Any,',
        '"next_due_meter_value": task.nextDueMeterValue.map { NSDecimalNumber(decimal: $0).stringValue } as Any,',
    )
    text = text.replace(
        '"meter_interval_value": task.meterIntervalValue as Any,',
        '"meter_interval_value": task.meterIntervalValue.map { NSDecimalNumber(decimal: $0).stringValue } as Any,',
    )
    if "static func decodeFlexibleDecimal" not in text:
        helper = '''
    static func decodeFlexibleDecimal(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Decimal? {
        if let v = try? c.decodeIfPresent(Decimal.self, forKey: key) { return v }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Decimal(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Decimal(string: String(d))
        }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return Decimal(string: s.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }
'''
        # Insert before decodeFlexibleDouble if present
        if "static func decodeFlexibleDouble" in text:
            text = text.replace(
                "static func decodeFlexibleDouble",
                helper + "\n    static func decodeFlexibleDouble",
                1,
            )
            print("patched: API decodeFlexibleDecimal")
        else:
            text += helper
            print("patched: API decodeFlexibleDecimal (append)")
    return text


def main() -> int:
    if not SWIFT.is_file():
        raise SystemExit(f"missing {SWIFT}")
    if not API.is_file():
        raise SystemExit(f"missing {API}")

    swift = SWIFT.read_text(encoding="utf-8")
    swift = patch_model(swift)
    swift = patch_helpers_and_ui(swift)
    SWIFT.write_text(swift, encoding="utf-8")

    api = API.read_text(encoding="utf-8")
    api = patch_api(api)
    API.write_text(api, encoding="utf-8")

    manual = APP_ROOT / "Sources/PropertyManagerApp/ManualImport.swift"
    if manual.is_file():
        mt = manual.read_text(encoding="utf-8")
        old = (
            "            manualImport: record,\n"
            "            scheduleKind: scheduleKind,\n"
            "            meterIntervalValue: parsedValue,\n"
            "            meterIntervalUnit: parsedUnit\n"
        )
        new = (
            "            manualImport: record,\n"
            "            scheduleKind: scheduleKind,\n"
            "            meterIntervalValue: parsedValue.map { Decimal($0) },\n"
            "            meterIntervalUnit: parsedUnit\n"
        )
        if old in mt:
            manual.write_text(mt.replace(old, new, 1), encoding="utf-8")
            print("patched: ManualImport Decimal convert")
        else:
            print("skip: ManualImport Decimal convert")

    print("OK: run-hours corrections applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
