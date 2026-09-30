import Foundation

/// Raw values match the Mac app and the API `frequency` column.
enum ManualTaskFrequency: String, CaseIterable {
    case daily = "Daily"
    case weekly = "Weekly"
    case biweekly = "Every 2 Weeks"
    case monthly = "Monthly"
    case quarterly = "Quarterly"
    case yearly = "Yearly"
}

/// Turns the interval the manual prints into a calendar schedule. The on-device
/// model is only asked to copy that wording; its own day estimates defaulted to daily.
struct ManualInterval: Equatable {
    let frequency: ManualTaskFrequency
    let warningDays: Int
    /// Manufacturer wording kept in the task notes when the calendar schedule is an approximation.
    let note: String?

    var criticalDays: Int { max(warningDays * 2, warningDays + 7) }

    static func from(_ raw: String) -> ManualInterval? {
        let stated = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stated.isEmpty else { return nil }
        let text = stated.lowercased()
        let approximate = "Manufacturer interval: \(stated)."
        let contains: (String) -> Bool = { text.contains($0) }

        if text.range(of: #"\d+\s*(operating\s+)?(hours?|hrs?)\b"#, options: .regularExpression) != nil {
            return ManualInterval(
                frequency: .monthly,
                warningDays: 30,
                note: approximate + " Set an hour trigger on the task if the asset has an hour meter."
            )
        }
        if ["each use", "every use", "before use", "after use", "daily", "every day", "each day"].contains(where: contains) {
            return ManualInterval(frequency: .daily, warningDays: 1, note: nil)
        }
        if ["2 week", "two week", "biweek", "every other week"].contains(where: contains) {
            return ManualInterval(frequency: .biweekly, warningDays: 14, note: nil)
        }
        if contains("week") {
            return ManualInterval(frequency: .weekly, warningDays: 7, note: nil)
        }
        if ["quarter", "3 month", "three month"].contains(where: contains) {
            return ManualInterval(frequency: .quarterly, warningDays: 90, note: nil)
        }
        if ["6 month", "six month", "twice a year", "semi-annual"].contains(where: contains) {
            return ManualInterval(frequency: .yearly, warningDays: 180, note: approximate)
        }
        if contains("month") {
            return ManualInterval(frequency: .monthly, warningDays: 30, note: nil)
        }
        if ["year", "annual", "season", "storage", "winter"].contains(where: contains) {
            return ManualInterval(frequency: .yearly, warningDays: 365, note: nil)
        }
        return ManualInterval(frequency: .monthly, warningDays: 30, note: approximate)
    }
}

enum ManualTaskCategory {
    static func from(_ raw: String?, area: String) -> String {
        let text = (raw ?? area).lowercased()
        if text.contains("pool") { return "Pool" }
        if text.contains("hot") || text.contains("tub") || text.contains("spa") { return "Home" }
        if text.contains("fence") || text.contains("gate") || text.contains("property") { return "Property" }
        if text.contains("ground") || text.contains("yard") || text.contains("lawn") { return "Grounds" }
        if text.contains("safety") || text.contains("fire") { return "Safety" }
        if text.contains("house") || text.contains("home") || text.contains("softener") { return "House" }
        return "Equipment"
    }
}

struct ManualToolRequirement: Equatable, Hashable {
    var name: String
    var size: String
    var notes: String
}

struct ManualImportDraft: Identifiable, Equatable {
    let id = UUID()
    var selected: Bool = true
    var area: String
    var item: String
    var category: String
    var frequency: ManualTaskFrequency
    var warningDays: Int
    var criticalDays: Int
    var estimatedMinutes: Int
    var taskDescription: String
    var responseInstructions: String
    var suppliesNeeded: String
    var notes: String
    var manufacturer: String
    var sourceManualName: String
    var partNumbers: [String]
    var referenceURLs: [String]
    var toolsRequired: [ManualToolRequirement]

    /// Same maintenance action already stored for this asset. Area and manual
    /// file names are excluded so a second publication does not look new.
    var maintenanceIdentity: String {
        ManualMaintenanceIdentity.make(area: area, item: item)
    }

    /// Same POST /tasks body the Mac app sends for an imported manufacturer task.
    func taskPayload(assetID: UUID, lastDone: Date = Date()) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let nextDue = Calendar.current.date(byAdding: .day, value: warningDays, to: lastDone) ?? lastDone
        let partCount = max(partNumbers.count, referenceURLs.count)
        let parts: [[String: Any]] = (0..<partCount).map { index in
            [
                "id": UUID().uuidString,
                "name": "Part \(index + 1)",
                "oem_part_number": "",
                "part_number": index < partNumbers.count ? partNumbers[index] : "",
                "buy_url": index < referenceURLs.count ? referenceURLs[index] : "",
                "cost": 0,
                "quantity": 1,
                "sort_order": index,
            ]
        }
        return [
            "id": UUID().uuidString,
            "area": area,
            "item": item,
            "category_name": category,
            "kind": "Scheduled",
            "priority": "Medium",
            "frequency": frequency.rawValue,
            "task_description": taskDescription,
            "response_instructions": responseInstructions,
            "supplies_needed": suppliesNeeded,
            "notes": notes,
            "result_notes": "",
            "estimated_minutes": estimatedMinutes,
            "warning_days": warningDays,
            "critical_days": criticalDays,
            "last_done": iso.string(from: lastDone),
            "next_due": iso.string(from: nextDue),
            "send_telegram_update": true,
            "include_in_daily_briefing": true,
            "alert_if_overdue": true,
            "is_active": true,
            "manufacturer": manufacturer,
            "source_manual_name": sourceManualName,
            "origin": TaskOrigin.manufacturer.rawValue,
            "completion_history": [String](),
            "tools_required": toolsRequired.map { tool -> [String: Any] in
                ["id": UUID().uuidString, "name": tool.name, "size": tool.size, "notes": tool.notes]
            },
            "schedule_kind": "calendar",
            "meter_interval_value": NSNull(),
            "meter_interval_unit": NSNull(),
            "next_due_meter_value": NSNull(),
            "asset_id": assetID.uuidString,
            "parts": parts,
        ]
    }
}

enum ManualMaintenanceIdentity {
    static func make(area: String, item: String) -> String {
        let bareItem = stripLeadingAreaPrefix(item, area: area)
        return semanticTaskKey(stripEquipmentHeadings(bareItem))
    }

    static func taskIdentity(_ task: MaintenanceTask) -> String {
        make(area: task.area, item: task.item)
    }

    private static let fillerWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "for", "to", "on", "in", "with", "any", "all", "if", "is", "be", "as",
    ]
    private static let actionSynonyms = ["inspect": "check", "examine": "check", "verify": "check"]

    /// Content words of an identity key, with the leading action normalized so
    /// "Inspect the knife" and "Check knife" compare equal.
    static func contentWords(ofKey key: String) -> [String] {
        var words = key.split(separator: " ").map(String.init).filter { !fillerWords.contains($0) }
        if let first = words.first, let synonym = actionSynonyms[first] {
            words[0] = synonym
        }
        return words
    }

    /// Same action on the same parts, allowing extra qualifiers such as
    /// "for tightness, nicks, wear". Distinct actions (check vs replace) never match.
    static func isSameAction(_ lhsKey: String, _ rhsKey: String) -> Bool {
        if lhsKey == rhsKey { return true }
        let lhs = contentWords(ofKey: lhsKey)
        let rhs = contentWords(ofKey: rhsKey)
        guard let lhsAction = lhs.first, lhsAction == rhs.first else { return false }
        let smaller = Set(lhs.count <= rhs.count ? lhs : rhs)
        let larger = Set(lhs.count <= rhs.count ? rhs : lhs)
        guard smaller.count >= 3 else { return smaller == larger }
        return Double(smaller.intersection(larger).count) / Double(smaller.count) >= 0.8
    }

    private static func stripLeadingAreaPrefix(_ item: String, area: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = area.trimmingCharacters(in: .whitespacesAndNewlines) + ":"
        guard !prefix.isEmpty, trimmed.lowercased().hasPrefix(prefix.lowercased()) else {
            return trimmed
        }
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Drop a leading equipment or subsystem heading such as
    /// "JD 1025R Tractor:" so it can match the same action stored earlier.
    private static func stripEquipmentHeadings(_ item: String) -> String {
        var title = item.trimmingCharacters(in: .whitespacesAndNewlines)
        while let colon = title.firstIndex(of: ":") {
            let normalized = String(title[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isEquipmentHeading = ["tractor", "mower", "generator", "ranger", "equipment", "chipper"]
                .contains { normalized.contains($0) }
            let isSubsystemHeading = ["engine", "brush deck", "deck", "brakes", "brake", "battery", "fuel system"]
                .contains(normalized)
            guard isEquipmentHeading || isSubsystemHeading else { break }
            title = String(title[title.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
        }
        return title
    }

    /// Match wording variants of the same manufacturer recommendation without
    /// collapsing distinct work (for example, checking oil vs changing oil).
    private static func semanticTaskKey(_ item: String) -> String {
        let value = foldPlurals(normalize(item))
        let contains: (String) -> Bool = { value.contains($0) }

        if (contains("check") || contains("inspect") || contains("adjust")) && contains("valve clearance") {
            return "check engine valve clearance"
        }
        if (contains("check") || contains("inspect")) && contains("engine oil") { return "check engine oil" }
        if contains("change") && contains("oil") { return "change engine oil" }
        if contains("air filter") { return "air filter service" }
        if contains("fuel filter") { return "fuel filter service" }
        if contains("fuel line") { return "fuel lines service" }
        if contains("blade belt") && (contains("replace") || contains("replacing")) { return "replace blade belt" }
        if contains("belt") && (contains("check") || contains("inspect")) { return "inspect belts" }
        if contains("tire pressure") { return "check tire pressure" }
        if contains("battery") && (contains("charge") || contains("charging")) { return "charge battery" }
        if contains("battery") && contains("replace") { return "replace battery" }
        if contains("battery") && (contains("clean") || contains("check") || contains("inspect")) {
            return "clean battery"
        }
        if contains("brake cable") { return "adjust brake cables" }
        if contains("brake pad") { return "adjust brake pads" }
        if contains("caliper alignment") { return "adjust caliper alignment" }
        if contains("blade") && (contains("sharp") || contains("nicks") || contains("wear")) { return "inspect mower blade" }
        if (contains("lubricate") || contains("grease"))
            && !contains("steering") && !contains("cable") && !contains("idler")
            && (contains("grease") || contains("fitting") || value == "lubricate machine") {
            return "lubricate grease fittings"
        }
        if (contains("check") || contains("inspect") || contains("test"))
            && (contains("safety interlock") || (contains("safety") && contains("system"))) {
            return "check safety systems"
        }
        if (contains("check") || contains("inspect") || contains("verify")) && contains("transmission oil")
            && !contains("drain") && !contains("refill") && !contains("replace") && !contains("install") {
            return "check transmission oil"
        }
        if (contains("check") || contains("inspect")) && contains("coolant")
            && !contains("drain") && !contains("flush") && !contains("refill") {
            return "check coolant"
        }
        return value
    }

    private static func foldPlurals(_ value: String) -> String {
        let singular = [
            "filters": "filter",
            "fittings": "fitting",
            "elements": "element",
            "screens": "screen",
            "hoses": "hose",
            "clamps": "clamp",
        ]
        return value.split(separator: " ").map { singular[String($0)] ?? String($0) }.joined(separator: " ")
    }
}

enum ManualImportReviewSelection {
    /// `existingTasks` comes from GET /tasks, which already excludes work requests.
    static func notes(
        drafts: [ManualImportDraft],
        existingTasks: [MaintenanceTask],
        assetID: UUID
    ) -> [UUID: String] {
        let stored = existingTasks
            .filter { $0.assetId == assetID && $0.isActive }
            .map { (key: ManualMaintenanceIdentity.taskIdentity($0), item: $0.item) }

        var notes: [UUID: String] = [:]
        var proposals: [(key: String, item: String)] = []
        for draft in drafts {
            let key = draft.maintenanceIdentity
            if let match = stored.first(where: { ManualMaintenanceIdentity.isSameAction(key, $0.key) }) {
                notes[draft.id] = "Duplicate of stored task: \(match.item)"
            } else if let earlier = proposals.first(where: { ManualMaintenanceIdentity.isSameAction(key, $0.key) }) {
                notes[draft.id] = "Duplicate of another proposal: \(earlier.item)"
            } else {
                proposals.append((key, draft.item))
            }
        }
        return notes
    }

    static func applyingDefaultSelection(
        drafts: [ManualImportDraft],
        existingTasks: [MaintenanceTask],
        assetID: UUID
    ) -> [ManualImportDraft] {
        let duplicateIDs = Set(notes(drafts: drafts, existingTasks: existingTasks, assetID: assetID).keys)
        return drafts.map { draft in
            var copy = draft
            copy.selected = !duplicateIDs.contains(draft.id)
            return copy
        }
    }
}

/// Manual models frequently repeat the equipment name and section heading in a
/// task title. The task formatter adds the linked asset once for display, so
/// imported titles must retain only the maintenance action.
enum ManualTaskTitle {
    static func clean(
        _ raw: String,
        equipmentName: String,
        subsystem: String?,
        supportingText: String? = nil
    ) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [equipmentName, subsystem ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in prefixes {
                let marker = "\(prefix):"
                if title.lowercased().hasPrefix(marker.lowercased()) {
                    title = String(title.dropFirst(marker.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
                    removedPrefix = true
                }
            }
        }

        // Strip only unmistakable equipment/subsystem headings; do not remove
        // an action such as `Replace blade belt`.
        while let colon = title.firstIndex(of: ":") {
            let normalized = String(title[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isEquipmentHeading = [" mower", " tractor", " generator", " ranger", " equipment"]
                .contains { normalized.contains($0) }
            let isSubsystemHeading = ["engine", "brush deck", "deck", "brakes", "brake", "battery", "fuel system"]
                .contains(normalized)
            guard isEquipmentHeading || isSubsystemHeading else { break }
            title = String(title[title.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
        }

        if containsAction(title) { return title }
        if let supportingText, let action = actionTitle(in: supportingText) { return action }
        return title.isEmpty ? "Maintenance item" : title
    }

    private static func containsAction(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["change ", "replace ", "check ", "inspect ", "clean ", "adjust ", "lubricate ",
                "charge ", "sharpen ", "remove ", "install ", "service ", "maintain "]
            .contains { lower.hasPrefix($0) }
    }

    private static func actionTitle(in supportingText: String) -> String? {
        let pattern = #"(?is)\b(change|replace|check|inspect|clean|adjust|lubricate|charge|sharpen|remove|install|service|maintain)\b[^\.\n]{1,110}"#
        guard let range = supportingText.range(of: pattern, options: .regularExpression) else { return nil }
        let candidate = supportingText[range]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-•[]"))
        guard !candidate.isEmpty else { return nil }
        return candidate.prefix(1).uppercased() + candidate.dropFirst()
    }
}

/// Literal manufacturer recommendations found in the extracted PDF text. Kept
/// identical to the Mac verifier: no inferred intervals and no automatic records.
enum ManualSourceBackedDrafts {
    static func drafts(manualName: String, manualText: String, manufacturer: String) -> [ManualImportDraft] {
        let text = manualText.lowercased()
        let equipment = manualName
            .replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var drafts: [ManualImportDraft] = []

        func add(
            when phrase: String,
            item: String,
            frequency: ManualTaskFrequency,
            warningDays: Int,
            instructions: String,
            supplies: String = ""
        ) {
            guard text.contains(phrase) else { return }
            drafts.append(ManualImportDraft(
                area: equipment,
                item: item,
                category: "Equipment",
                frequency: frequency,
                warningDays: warningDays,
                criticalDays: max(warningDays * 2, warningDays + 7),
                estimatedMinutes: 20,
                taskDescription: item,
                responseInstructions: instructions,
                suppliesNeeded: supplies,
                notes: "Source manual: \(manualName)\nManufacturer wording verified in extracted PDF text.",
                manufacturer: manufacturer,
                sourceManualName: manualName,
                partNumbers: [],
                referenceURLs: [],
                toolsRequired: []
            ))
        }

        add(
            when: "check the engine oil level",
            item: "Check engine oil level",
            frequency: .daily,
            warningDays: 1,
            instructions: "Check the engine oil level before each use, as directed by the manufacturer."
        )
        add(
            when: "check belts for wear",
            item: "Inspect belts for wear, alignment, and tension",
            frequency: .daily,
            warningDays: 1,
            instructions: "Before each use, inspect belts for wear, proper alignment, and tension."
        )
        add(
            when: "change the oil",
            item: "Change engine oil",
            frequency: .yearly,
            warningDays: 365,
            instructions: "For end-of-season storage, change the engine oil and replace the oil filter if applicable."
        )
        add(
            when: "clean/replace the air filters",
            item: "Clean or replace air filter",
            frequency: .yearly,
            warningDays: 365,
            instructions: "For end-of-season storage, clean or replace the air filter."
        )
        add(
            when: "if your engine has a fuel filter",
            item: "Replace fuel filter",
            frequency: .yearly,
            warningDays: 365,
            instructions: "If the engine has a fuel filter, replace it during end-of-season service."
        )
        add(
            when: "replace rubber fuel lines and grommets",
            item: "Replace rubber fuel lines and grommets",
            frequency: .yearly,
            warningDays: 365 * 5,
            instructions: "Replace rubber fuel lines and grommets when worn or damaged, or after five years of use, whichever comes first."
        )
        add(
            when: "removing and replacing the blade belt",
            item: "Replace blade belt",
            frequency: .yearly,
            warningDays: 365,
            instructions: "Replace the blade belt using the manufacturer’s belt-guard, pulley, tensioner-spring, and routing procedure.",
            supplies: "Gloves"
        )
        add(
            when: "adjusting the brake cables",
            item: "Adjust brake cables",
            frequency: .yearly,
            warningDays: 365,
            instructions: "Use the brake caliper micro-adjust knob; when it reaches the end of its travel, perform the full cable adjustment procedure.",
            supplies: "5.5 mm Allen wrench"
        )
        add(
            when: "battery care",
            item: "Charge stored battery",
            frequency: .monthly,
            warningDays: 35,
            instructions: "When the machine is not in use, charge the battery every four to six weeks."
        )
        return drafts
    }
}
