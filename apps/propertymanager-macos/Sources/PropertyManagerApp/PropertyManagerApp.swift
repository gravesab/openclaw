import SwiftUI
import Combine
import Foundation
import AppKit
import EventKit
import UniformTypeIdentifiers
import PDFKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    static func from(storageValue: String) -> AppAppearance {
        AppAppearance(rawValue: storageValue) ?? .system
    }
}

@main
struct PropertyManagerApp: App {
    @StateObject private var store = MaintenanceStore()
    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1050, minHeight: 720)
                .preferredColorScheme(AppAppearance.from(storageValue: appearanceRaw).colorScheme)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
    }
}

enum TaskCategory: String, CaseIterable, Codable, Identifiable {
    case pool = "Pool"
    case hotTub = "Hot Tub"
    case grounds = "Grounds"
    case equipment = "Equipment"
    case house = "House"
    case safety = "Safety"
    case property = "Property"

    var id: String { rawValue }

    var icon: String { CategoryStyle.icon(for: rawValue) }
    var color: Color { CategoryStyle.color(for: rawValue) }
}

struct CategoryDefinition: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var colorName: String
    var isBuiltIn: Bool
}

enum TaskKind: String, CaseIterable, Codable, Identifiable {
    case scheduled = "Scheduled"
    case workRequest = "Work Request"

    var id: String { rawValue }
}

enum TaskOrigin: String, CaseIterable, Codable, Identifiable {
    case manufacturer
    case owner

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manufacturer: return "Manufacturer"
        case .owner: return "Owner-added"
        }
    }
}

enum TaskPriority: String, CaseIterable, Codable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }
}

enum TaskFrequency: String, CaseIterable, Codable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case biweekly = "Every 2 Weeks"
    case monthly = "Monthly"
    case quarterly = "Quarterly"
    case everyThreeToFourMonths = "Every 3-4 Months"
    case yearly = "Yearly"
    case biennial = "Every 2 Years"

    var id: String { rawValue }

    /// Next calendar due after `lastDone` for this frequency.
    /// Warning/critical days are separate OpenClaw thresholds, not the interval.
    func nextDue(after lastDone: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: lastDone) ?? lastDone
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: lastDone) ?? lastDone
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14, to: lastDone) ?? lastDone
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: lastDone) ?? lastDone
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3, to: lastDone) ?? lastDone
        case .everyThreeToFourMonths:
            return calendar.date(byAdding: .day, value: 105, to: lastDone) ?? lastDone
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: lastDone) ?? lastDone
        case .biennial:
            return calendar.date(byAdding: .year, value: 2, to: lastDone) ?? lastDone
        }
    }
}

struct MaintenanceTask: Identifiable, Codable, Equatable {
    var id: UUID
    var area: String
    var item: String
    var category: String
    var kind: TaskKind
    var priority: TaskPriority
    var frequency: TaskFrequency
    var taskDescription: String
    var responseInstructions: String
    var suppliesNeeded: String
    var notes: String
    var resultNotes: String
    var completionHistory: [String]
    var estimatedMinutes: Int
    var warningDays: Int
    var criticalDays: Int
    var lastDone: Date
    var nextDue: Date
    var sendTelegramUpdate: Bool
    var includeInDailyBriefing: Bool
    var alertIfOverdue: Bool
    var isActive: Bool
    var manufacturer: String
    var sourceManualName: String
    var origin: TaskOrigin
    var partNumbers: [String]
    var referenceURLs: [String]
    var toolsRequired: [ToolRequirement]
    var parts: [PartRequirement]
    var photoFileNames: [String]
    /// URL/PDF import provenance + source facts vs AI inference (nil/empty for legacy tasks).
    var manualImport: ManualURLImportRecord?
    var scheduleKind: String = "calendar"
    var meterIntervalValue: Decimal? = nil
    var meterIntervalUnit: String? = nil
    var nextDueMeterValue: Decimal? = nil
    var remainingMeter: Decimal? = nil
    var dueMeter: Bool? = nil
    var overdueMeter: Bool? = nil
    var assetId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, area, item, category, kind, priority, frequency
        case taskDescription, responseInstructions, suppliesNeeded, notes, resultNotes
        case completionHistory, estimatedMinutes, warningDays, criticalDays
        case lastDone, nextDue, sendTelegramUpdate, includeInDailyBriefing
        case alertIfOverdue, isActive
        case manufacturer, sourceManualName, origin, partNumbers, referenceURLs, toolsRequired, parts, photoFileNames
        case manualImport
        case scheduleKind, meterIntervalValue, meterIntervalUnit, nextDueMeterValue, remainingMeter, dueMeter, overdueMeter, assetId
    }

    init(
        id: UUID = UUID(),
        area: String,
        item: String,
        category: String,
        kind: TaskKind = .scheduled,
        priority: TaskPriority,
        frequency: TaskFrequency,
        taskDescription: String,
        responseInstructions: String,
        suppliesNeeded: String = "",
        notes: String = "",
        resultNotes: String = "",
        completionHistory: [String] = [],
        estimatedMinutes: Int = 30,
        warningDays: Int,
        criticalDays: Int,
        lastDone: Date,
        nextDue: Date,
        sendTelegramUpdate: Bool = true,
        includeInDailyBriefing: Bool = true,
        alertIfOverdue: Bool = true,
        isActive: Bool = true,
        manufacturer: String = "",
        sourceManualName: String = "",
        origin: TaskOrigin = .owner,
        partNumbers: [String] = [],
        referenceURLs: [String] = [],
        toolsRequired: [ToolRequirement] = [],
        parts: [PartRequirement] = [],
        photoFileNames: [String] = [],
        manualImport: ManualURLImportRecord? = nil,
        scheduleKind: String = "calendar",
        meterIntervalValue: Decimal? = nil,
        meterIntervalUnit: String? = nil,
        nextDueMeterValue: Decimal? = nil,
        remainingMeter: Decimal? = nil,
        dueMeter: Bool? = nil,
        overdueMeter: Bool? = nil,
        assetId: UUID? = nil
    ) {
        self.id = id
        self.area = area
        self.item = item
        self.category = category
        self.kind = kind
        self.priority = priority
        self.frequency = frequency
        self.taskDescription = taskDescription
        self.responseInstructions = responseInstructions
        self.suppliesNeeded = suppliesNeeded
        self.notes = notes
        self.resultNotes = resultNotes
        self.completionHistory = completionHistory
        self.estimatedMinutes = estimatedMinutes
        self.warningDays = warningDays
        self.criticalDays = criticalDays
        self.lastDone = lastDone
        self.nextDue = nextDue
        self.sendTelegramUpdate = sendTelegramUpdate
        self.includeInDailyBriefing = includeInDailyBriefing
        self.alertIfOverdue = alertIfOverdue
        self.isActive = isActive
        self.manufacturer = manufacturer
        self.sourceManualName = sourceManualName
        self.origin = origin
        self.partNumbers = partNumbers
        self.referenceURLs = referenceURLs
        self.toolsRequired = toolsRequired
        self.parts = parts
        self.photoFileNames = photoFileNames
        self.manualImport = manualImport
        self.scheduleKind = scheduleKind
        self.meterIntervalValue = meterIntervalValue
        self.meterIntervalUnit = meterIntervalUnit
        self.nextDueMeterValue = nextDueMeterValue
        self.remainingMeter = remainingMeter
        self.dueMeter = dueMeter
        self.overdueMeter = overdueMeter
        self.assetId = assetId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        area = try c.decode(String.self, forKey: .area)
        item = try c.decode(String.self, forKey: .item)
        category = try c.decode(String.self, forKey: .category)
        kind = try c.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .scheduled
        priority = try c.decode(TaskPriority.self, forKey: .priority)
        frequency = try c.decode(TaskFrequency.self, forKey: .frequency)
        taskDescription = try c.decode(String.self, forKey: .taskDescription)
        responseInstructions = try c.decode(String.self, forKey: .responseInstructions)
        suppliesNeeded = try c.decodeIfPresent(String.self, forKey: .suppliesNeeded) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        resultNotes = try c.decodeIfPresent(String.self, forKey: .resultNotes) ?? ""
        completionHistory = try c.decodeIfPresent([String].self, forKey: .completionHistory) ?? []
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 30
        warningDays = try c.decode(Int.self, forKey: .warningDays)
        criticalDays = try c.decode(Int.self, forKey: .criticalDays)
        lastDone = try c.decode(Date.self, forKey: .lastDone)
        nextDue = try c.decode(Date.self, forKey: .nextDue)
        sendTelegramUpdate = try c.decodeIfPresent(Bool.self, forKey: .sendTelegramUpdate) ?? true
        includeInDailyBriefing = try c.decodeIfPresent(Bool.self, forKey: .includeInDailyBriefing) ?? true
        alertIfOverdue = try c.decodeIfPresent(Bool.self, forKey: .alertIfOverdue) ?? true
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
        sourceManualName = try c.decodeIfPresent(String.self, forKey: .sourceManualName) ?? ""
        if let decodedOrigin = try c.decodeIfPresent(TaskOrigin.self, forKey: .origin) {
            origin = decodedOrigin
        } else {
            origin = sourceManualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .owner : .manufacturer
        }
        partNumbers = try c.decodeIfPresent([String].self, forKey: .partNumbers) ?? []
        referenceURLs = try c.decodeIfPresent([String].self, forKey: .referenceURLs) ?? []
        toolsRequired = try c.decodeIfPresent([ToolRequirement].self, forKey: .toolsRequired) ?? []
        parts = try c.decodeIfPresent([PartRequirement].self, forKey: .parts) ?? []
        photoFileNames = try c.decodeIfPresent([String].self, forKey: .photoFileNames) ?? []
        manualImport = try c.decodeIfPresent(ManualURLImportRecord.self, forKey: .manualImport)
        if parts.isEmpty {
            parts = PartRequirement.migrated(fromPartNumbers: partNumbers, urls: referenceURLs)
        }
        scheduleKind = try c.decodeIfPresent(String.self, forKey: .scheduleKind) ?? "calendar"
        meterIntervalValue = try Self.decodeOptionalDecimal(c, forKey: .meterIntervalValue)
        meterIntervalUnit = try c.decodeIfPresent(String.self, forKey: .meterIntervalUnit)
        nextDueMeterValue = try Self.decodeOptionalDecimal(c, forKey: .nextDueMeterValue)
        remainingMeter = try Self.decodeOptionalDecimal(c, forKey: .remainingMeter)
        dueMeter = try c.decodeIfPresent(Bool.self, forKey: .dueMeter)
        overdueMeter = try c.decodeIfPresent(Bool.self, forKey: .overdueMeter)
        assetId = try c.decodeIfPresent(UUID.self, forKey: .assetId)
    }

    /// Keep Mac-only editor fields when an API response omits them.
    func mergingEditorFields(from local: MaintenanceTask) -> MaintenanceTask {
        var merged = self
        if merged.manualImport == nil {
            merged.manualImport = local.manualImport
        }
        if merged.photoFileNames.isEmpty, !local.photoFileNames.isEmpty {
            merged.photoFileNames = local.photoFileNames
        }
        if merged.responseInstructions.isEmpty, !local.responseInstructions.isEmpty {
            merged.responseInstructions = local.responseInstructions
        }
        return merged
    }
}

@MainActor
final class MaintenanceStore: ObservableObject {
    @Published var tasks: [MaintenanceTask] = []
    @Published var categories: [CategoryDefinition] = []
    @Published var selectedTaskID: UUID?
    @Published var statusMessage: String = "Ready"
    @Published var isOnline: Bool = false
    @Published var lastSyncAt: Date?
    @Published var hasLocalChanges: Bool = false
    @Published var lastPullAt: Date?
    @Published var lastPublishAt: Date?
    @Published var assets: [MacRanchAsset] = []
    @Published var showAssetsPanel: Bool = false
    @Published var calendarSyncMessage: String = ""
    @Published var isSyncingCalendar: Bool = false

    private let apiBaseURLKey = "propertyManager.apiBaseURL"
    private let apiKeyKey = "propertyManager.apiKey"
    private let operatorPINKey = "propertyManager.operatorPIN"
    private var autosaveTask: Task<Void, Never>?

    var apiBaseURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: apiBaseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
            return "http://192.168.50.117:15062"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: apiBaseURLKey)
        }
    }

    var apiKey: String {
        get { SecureCredentialStore.read("api-key") }
        set {
            objectWillChange.send()
            SecureCredentialStore.write(newValue, account: "api-key")
            UserDefaults.standard.removeObject(forKey: apiKeyKey)
        }
    }

    var operatorPIN: String {
        get { SecureCredentialStore.read("operator-pin") }
        set {
            objectWillChange.send()
            SecureCredentialStore.write(newValue, account: "operator-pin")
            UserDefaults.standard.removeObject(forKey: operatorPINKey)
        }
    }

    // MARK: Calendar sync settings (UserDefaults)

    /// Hour (0–23) at which the first timed block starts. Default 8 = 8:00 AM.
    var calendarStartHour: Int {
        get { UserDefaults.standard.object(forKey: "propertyManager.calendarStartHour") as? Int ?? 8 }
        set { UserDefaults.standard.set(newValue, forKey: "propertyManager.calendarStartHour") }
    }

    /// Minute (0 or 30) offset for the block start time. Default 0.
    var calendarStartMinute: Int {
        get { UserDefaults.standard.object(forKey: "propertyManager.calendarStartMinute") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "propertyManager.calendarStartMinute") }
    }

    /// DEV or prod sync environment. Default `.dev` while building on M4.
    var calendarSyncEnv: SyncEnv {
        get {
            let raw = UserDefaults.standard.string(forKey: "propertyManager.calendarSyncEnv") ?? SyncEnv.dev.rawValue
            return SyncEnv(rawValue: raw) ?? .dev
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "propertyManager.calendarSyncEnv") }
    }

    /// When true, completing a task in the Mac app immediately removes its
    /// OpenClaw calendar event.  Flip to false to disable without code change.
    var removeCalendarEventOnComplete: Bool {
        get {
            let v = UserDefaults.standard.object(forKey: "propertyManager.removeCalendarEventOnComplete")
            return v as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "propertyManager.removeCalendarEventOnComplete") }
    }

    var apiClient: PropertyAPIClient {
        PropertyAPIClient(baseURLString: apiBaseURL, apiKey: apiKey, operatorPIN: operatorPIN)
    }

    private var appSupportFolder: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let folder = appSupport.appendingPathComponent("PropertyManagerApp", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        return folder
    }

    private var saveURL: URL {
        appSupportFolder.appendingPathComponent("maintenance_tasks.json")
    }

    private var categoriesURL: URL {
        appSupportFolder.appendingPathComponent("maintenance_categories.json")
    }

    private var stagingCSVURL: URL {
        appSupportFolder.appendingPathComponent("staging_publish.csv")
    }

    private var syncStateURL: URL {
        appSupportFolder.appendingPathComponent("sync_state.json")
    }

    private struct SyncState: Codable {
        var hasLocalChanges: Bool
        var lastPullAt: Date?
        var lastPublishAt: Date?
    }

    init() {
        SecureCredentialStore.migrateFromUserDefaults(key: apiKeyKey, account: "api-key")
        SecureCredentialStore.migrateFromUserDefaults(key: operatorPINKey, account: "operator-pin")
        loadCategories()
        loadSyncState()
        load()
        // Network refresh is deferred to ContentView.task so the window can appear
        // before any API work. Launching refresh here deadlocks SwiftUI on macOS
        // (Published updates from a concurrent Task vs UpdateGroup during window load).
    }

    private func loadSyncState() {
        do {
            guard FileManager.default.fileExists(atPath: syncStateURL.path) else {
                return
            }

            let data = try Data(contentsOf: syncStateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(SyncState.self, from: data)
            hasLocalChanges = state.hasLocalChanges
            lastPullAt = state.lastPullAt
            lastPublishAt = state.lastPublishAt
        } catch {
            // Keep defaults if sync state is unreadable.
        }
    }

    private func persistSyncState() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let state = SyncState(
                hasLocalChanges: hasLocalChanges,
                lastPullAt: lastPullAt,
                lastPublishAt: lastPublishAt
            )
            let data = try encoder.encode(state)
            try data.write(to: syncStateURL, options: [.atomic])
        } catch {
            // Non-fatal; tasks still save.
        }
    }

    func loadCategories() {
        do {
            let url = categoriesURL

            guard FileManager.default.fileExists(atPath: url.path) else {
                categories = Self.defaultCategories()
                saveCategories()
                return
            }

            let data = try Data(contentsOf: url)
            categories = try JSONDecoder().decode([CategoryDefinition].self, from: data)

            if categories.isEmpty {
                categories = Self.defaultCategories()
                saveCategories()
            } else {
                ensureBuiltInCategories()
            }
        } catch {
            categories = Self.defaultCategories()
            saveCategories()
        }
    }

    func saveCategories() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(categories)
            try data.write(to: categoriesURL, options: [.atomic])
        } catch {
            // Category persistence is not yet user-facing; leave statusMessage unchanged.
        }
    }

    static func defaultCategories() -> [CategoryDefinition] {
        CategoryStyle.builtInNames.map { name in
            CategoryDefinition(
                id: UUID(),
                name: name,
                icon: CategoryStyle.icon(for: name),
                colorName: CategoryStyle.colorName(for: name),
                isBuiltIn: true
            )
        }
    }

    func addCategory(named rawName: String, icon: String = "folder.fill", colorName: String = "gray") -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Category name cannot be empty."
            return false
        }
        if categories.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            statusMessage = "Category \(name) already exists."
            return false
        }
        let created = CategoryDefinition(
            id: UUID(),
            name: name,
            icon: icon.isEmpty ? CategoryStyle.icon(for: name) : icon,
            colorName: colorName.isEmpty ? CategoryStyle.colorName(for: name) : colorName,
            isBuiltIn: false
        )
        categories.append(created)
        saveCategories()
        Task { @MainActor in
            do {
                let remote = try await apiClient.createCategory(created)
                if let index = categories.firstIndex(where: { $0.id == created.id || $0.name.caseInsensitiveCompare(remote.name) == .orderedSame }) {
                    categories[index] = remote
                } else {
                    categories.append(remote)
                }
                saveCategories()
                isOnline = true
                statusMessage = "Added category \(remote.name)."
            } catch {
                isOnline = false
                statusMessage = "Category saved on Mac only: \(error.localizedDescription)"
            }
        }
        statusMessage = "Added category \(name)."
        return true
    }

    @discardableResult
    func activeTaskCount(inCategoryNamed name: String) -> Int {
        tasks.filter {
            $0.category.caseInsensitiveCompare(name) == .orderedSame
                || $0.area.caseInsensitiveCompare(name) == .orderedSame
        }.count
    }

    func destinationCategories(excluding name: String) -> [CategoryDefinition] {
        categories
            .filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func deleteCategory(_ category: CategoryDefinition, reassignTo: String? = nil) -> Bool {
        if category.name.caseInsensitiveCompare("House") == .orderedSame {
            statusMessage = "House cannot be deleted."
            return false
        }
        guard categories.contains(where: { $0.id == category.id }) else {
            statusMessage = "Category \(category.name) was not found."
            return false
        }

        let affected = activeTaskCount(inCategoryNamed: category.name)
        if affected > 0 {
            let destination = (reassignTo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else {
                statusMessage = "Choose a destination category before deleting \(category.name)."
                return false
            }
            guard destination.caseInsensitiveCompare(category.name) != .orderedSame else {
                statusMessage = "Destination must be a different category."
                return false
            }
            guard categories.contains(where: { $0.name.caseInsensitiveCompare(destination) == .orderedSame }) else {
                statusMessage = "Destination category \(destination) was not found."
                return false
            }

            var moved = 0
            for index in tasks.indices {
                let matchesCategory = tasks[index].category.caseInsensitiveCompare(category.name) == .orderedSame
                let matchesArea = tasks[index].area.caseInsensitiveCompare(category.name) == .orderedSame
                if matchesCategory || matchesArea {
                    tasks[index].category = destination
                    tasks[index].area = destination
                    moved += 1
                }
            }

            categories.removeAll { $0.id == category.id }
            saveCategories()
            writeLocalCacheOnly()
            let categoryID = category.id
            let categoryName = category.name
            let movedCount = moved
            let destinationName = destination
            Task { @MainActor in
                do {
                    _ = try await apiClient.deleteCategory(id: categoryID, reassignTo: destinationName)
                    for task in tasks where task.category.caseInsensitiveCompare(destinationName) == .orderedSame {
                        _ = try await apiClient.upsertTask(task)
                    }
                    await refreshFromServer()
                    statusMessage = "Deleted \(categoryName); moved \(movedCount) task\(movedCount == 1 ? "" : "s") to \(destinationName)"
                } catch {
                    isOnline = false
                    statusMessage = "Deleted on Mac; server: \(error.localizedDescription)"
                }
            }
            statusMessage = "Deleted \(category.name); moved \(moved) task\(moved == 1 ? "" : "s") to \(destination)"
            return true
        }

        categories.removeAll { $0.id == category.id }
        saveCategories()
        Task { @MainActor in
            do {
                _ = try await apiClient.deleteCategory(id: category.id)
                isOnline = true
                statusMessage = "Deleted \(category.name)"
            } catch {
                isOnline = false
                statusMessage = "Deleted on Mac; server: \(error.localizedDescription)"
            }
        }
        statusMessage = "Deleted \(category.name)"
        return true
    }

    func ensureBuiltInCategories() {
        var changed = false
        for name in CategoryStyle.builtInNames {
            if !categories.contains(where: { $0.name == name }) {
                categories.append(
                    CategoryDefinition(
                        id: UUID(),
                        name: name,
                        icon: CategoryStyle.icon(for: name),
                        colorName: CategoryStyle.colorName(for: name),
                        isBuiltIn: true
                    )
                )
                changed = true
            }
        }
        // Keep picker valid: any existing task area must appear as a category choice.
        for task in tasks {
            let area = task.area.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !area.isEmpty else { continue }
            if !categories.contains(where: { $0.name.caseInsensitiveCompare(area) == .orderedSame }) {
                categories.append(
                    CategoryDefinition(
                        id: UUID(),
                        name: area,
                        icon: CategoryStyle.icon(for: area),
                        colorName: CategoryStyle.colorName(for: area),
                        isBuiltIn: false
                    )
                )
                changed = true
            }
        }
        if changed {
            saveCategories()
        }
    }

    func normalizeTaskCategoriesToArea() {
        var changed = false
        for index in tasks.indices {
            let area = tasks[index].area.trimmingCharacters(in: .whitespacesAndNewlines)
            if !area.isEmpty, tasks[index].category != area {
                tasks[index].category = area
                changed = true
            }
        }
        if changed {
            save(markDirty: false)
        }
    }

    func load() {
        do {
            let url = saveURL

            guard FileManager.default.fileExists(atPath: url.path) else {
                tasks = Self.sampleTasks()
                selectedTaskID = tasks.first?.id
                save()
                return
            }

            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            tasks = try decoder.decode([MaintenanceTask].self, from: data)
            selectedTaskID = tasks.first?.id

            if tasks.isEmpty {
                tasks = Self.sampleTasks()
                selectedTaskID = tasks.first?.id
                save()
            }
        } catch {
            backupUnreadableSaveFile()
            tasks = Self.sampleTasks()
            selectedTaskID = tasks.first?.id
            statusMessage = "Started with sample tasks; unreadable data was backed up"
            save()
        }
    }

    func save(markDirty: Bool = true) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: saveURL, options: [.atomic])
            hasLocalChanges = false
            persistSyncState()
            if markDirty, let selectedTaskID,
               let task = tasks.first(where: { $0.id == selectedTaskID }) {
                scheduleAutosave(task)
            } else if !markDirty {
                statusMessage = isOnline ? "Saved" : "Saved offline cache"
            }
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func scheduleAutosave(_ task: MaintenanceTask) {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await upsertTaskToServer(task)
        }
    }

    /// Explicit Save: upsert selected task without completing it.
    @MainActor
    func saveSelectedTask() async {
        guard let selectedTaskID,
              let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) else {
            statusMessage = "Select a task to save."
            return
        }
        autosaveTask?.cancel()
        await upsertTaskToServer(tasks[index])
    }

    @MainActor
    func refreshAssets() async {
        do {
            assets = try await apiClient.fetchAssets()
        } catch {
            statusMessage = "Couldn’t load assets: \(error.localizedDescription)"
        }
    }


    // MARK: - Calendar sync (PM -> OpenClaw, one-way)

    /// Pushes today's due (and overdue/incomplete) tasks to the "OpenClaw"
    /// Apple Calendar as stacked timed blocks.
    /// Idempotent: re-running removes the old blocks first.
    /// Roll-forward: tasks where nextDue <= today keep appearing each day
    /// until the operator marks them complete in PM.
    @MainActor
    func pushToCalendar() async {
        guard !isSyncingCalendar else { return }
        isSyncingCalendar = true
        calendarSyncMessage = "Pushing to OpenClaw..."
        do {
            let count = try await CalendarSyncService.shared.pushTodaysTasks(
                tasks,
                startHour: calendarStartHour,
                startMinute: calendarStartMinute,
                env: calendarSyncEnv,
                assets: assets
            )
            if count == 0 {
                calendarSyncMessage = "0 due tasks (active, schedule calendar|both, nextDue ≤ today). Nothing pushed [\(calendarSyncEnv.label)]. Set a task Next Due to today to verify."
            } else {
                calendarSyncMessage = "Pushed \(count) task\(count == 1 ? "" : "s") [\(calendarSyncEnv.label)]"
            }
        } catch {
            calendarSyncMessage = "Calendar: \(error.localizedDescription)"
        }
        isSyncingCalendar = false
    }

    /// Deletes all PM events tagged env=dev from "OpenClaw" in a +/-90-day window.
    /// Run once before promoting to prod to clean the calendar of all DEV events.
    @MainActor
    func deleteDevCalendarEvents() async {
        guard !isSyncingCalendar else { return }
        isSyncingCalendar = true
        calendarSyncMessage = "Deleting DEV events..."
        do {
            let count = try await CalendarSyncService.shared.deleteDevEvents()
            calendarSyncMessage = "Deleted \(count) DEV event\(count == 1 ? "" : "s")"
        } catch {
            calendarSyncMessage = "Calendar: \(error.localizedDescription)"
        }
        isSyncingCalendar = false
    }

    /// Removes calendar events for a single task after Mac completion.
    /// Guarded by removeCalendarEventOnComplete (default true) -- flip that
    /// UserDefaults key to false to disable without any code change.
    /// iOS-only completions: nextDue advances past today on next Refresh, so
    /// the task falls out of the push filter on the next Push Today.
    @MainActor
    func removeCalendarEventsForTask(id taskId: UUID) async {
        guard removeCalendarEventOnComplete else { return }
        try? await CalendarSyncService.shared.removeEventsForTask(taskId: taskId)
    }

    private var isRefreshingFromServer = false

    func refreshFromServer() async {
        guard !isRefreshingFromServer else { return }
        isRefreshingFromServer = true
        defer { isRefreshingFromServer = false }

        statusMessage = "Connecting…"
        do {
            _ = try await apiClient.health()
            async let fetchedCategories = apiClient.fetchCategories()
            async let fetchedTasks = apiClient.fetchTasks()
            let remoteCategories = try await fetchedCategories
            let remoteTasks = try await fetchedTasks

            if !remoteCategories.isEmpty {
                categories = remoteCategories
                saveCategories()
            }
            tasks = remoteTasks
            if selectedTaskID == nil || !tasks.contains(where: { $0.id == selectedTaskID }) {
                selectedTaskID = tasks.first?.id
            }
            ensureBuiltInCategories()
            writeLocalCacheOnly()
            isOnline = true
            lastSyncAt = Date()
            lastPullAt = lastSyncAt
            hasLocalChanges = false
            persistSyncState()
            statusMessage = "Online · \(tasks.count) tasks"
        } catch {
            isOnline = false
            statusMessage = "Can’t reach server. Showing last saved tasks. \(error.localizedDescription)"
        }
    }

    private func writeLocalCacheOnly() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(tasks)
            try data.write(to: saveURL, options: [.atomic])
        } catch {
            // Non-fatal cache write.
        }
    }

    @MainActor
    func upsertTaskToServer(_ task: MaintenanceTask) async {
        statusMessage = "Saving…"
        do {
            var normalized = task
            let group = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: assets)
            normalized.area = group
            normalized.item = TaskTitle.canonicalItem(assetName: group, title: task.item)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].area = normalized.area
                tasks[index].item = normalized.item
            }
            let updated = try await apiClient.upsertTask(normalized)
            if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
                tasks[index] = updated
            } else {
                tasks.insert(updated, at: 0)
            }
            writeLocalCacheOnly()
            isOnline = true
            lastSyncAt = Date()
            hasLocalChanges = false
            persistSyncState()
            statusMessage = "Saved"
        } catch {
            isOnline = false
            statusMessage = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    @MainActor
    func completeSelectedTask() async {
        guard let selectedTaskID,
              let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) else {
            return
        }
        let note = tasks[index].resultNotes
        statusMessage = "Marking complete…"
        do {
            let updated = try await apiClient.completeTask(id: selectedTaskID, note: note)
            tasks[index] = updated.mergingEditorFields(from: tasks[index])
            writeLocalCacheOnly()
            isOnline = true
            lastSyncAt = Date()
            hasLocalChanges = false
            persistSyncState()
            statusMessage = "Completed · next due \(DateHelper.isoDate(updated.nextDue))"
            // Remove calendar event for this task (Apple Calendar is view-only; PM drives state).
            await removeCalendarEventsForTask(id: selectedTaskID)
        } catch {
            // Fallback: local complete + upsert so the UI still works if complete endpoint fails.
            markTaskCompleteLocally(at: index)
            await upsertTaskToServer(tasks[index])
            // Also remove calendar event on local-fallback path.
            await removeCalendarEventsForTask(id: selectedTaskID)
            if !statusMessage.hasPrefix("Couldn’t") {
                statusMessage = "Completed (synced)"
            }
        }
    }

    private func markTaskCompleteLocally(at index: Int) {
        tasks[index].lastDone = Date()
        tasks[index].nextDue = Calendar.current.date(
            byAdding: .day,
            value: tasks[index].warningDays,
            to: tasks[index].lastDone
        ) ?? tasks[index].lastDone
        let trimmedNotes = tasks[index].resultNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let completionDate = DateHelper.isoDate(tasks[index].lastDone)
        let historyNote: String
        if trimmedNotes.isEmpty || (trimmedNotes.hasPrefix("Completed on ") && trimmedNotes.hasSuffix(".")) {
            historyNote = "Completed on \(completionDate)."
            tasks[index].resultNotes = historyNote
        } else {
            historyNote = trimmedNotes
        }
        let entry = "\(completionDate) — \(historyNote)"
        if !tasks[index].completionHistory.contains(entry) {
            tasks[index].completionHistory.insert(entry, at: 0)
        }
    }

    func addTask(category filterCategory: String? = nil, kind: TaskKind = .scheduled) {
        let today = Date()
        let category = (filterCategory?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "House"
        // Area defaults to the category so Property filter -> Property task.
        // User can then change Area to something specific (Fence Line, Gate, etc.).
        let area = category
        let isWorkRequest = kind == .workRequest
        let bareItem = isWorkRequest ? "Describe the repair needed" : "Describe the work"
        let item = TaskTitle.canonicalItem(assetName: area, title: bareItem)
        let warning = isWorkRequest ? 1 : 30
        let critical = isWorkRequest ? 3 : 45
        let task = MaintenanceTask(
            area: area,
            item: item,
            category: category,
            kind: kind,
            priority: isWorkRequest ? .high : .medium,
            frequency: isWorkRequest ? .daily : .monthly,
            taskDescription: isWorkRequest
                ? "WORK REQUEST — found something that needs repair. Edit Item with location and problem."
                : "New \(category.lowercased()) task — edit Area, Item, and How-To.",
            responseInstructions: isWorkRequest
                ? """
                1. Confirm location: \(area).
                2. Describe the problem and safety risk.
                3. List parts/tools needed.
                4. Complete the repair or schedule a contractor.
                5. Mark Complete when finished.
                """
                : defaultResponse(forArea: area, item: item),
            notes: isWorkRequest ? "Work Request" : "",
            estimatedMinutes: isWorkRequest ? 60 : 30,
            warningDays: warning,
            criticalDays: critical,
            lastDone: today,
            nextDue: today,
            includeInDailyBriefing: true,
            alertIfOverdue: true
        )

        tasks.insert(task, at: 0)
        selectedTaskID = task.id
        writeLocalCacheOnly()
        Task { await upsertTaskToServer(task) }
        if isWorkRequest {
            statusMessage = "Work Request created under \(category). Edit Item, then keep working — it saves automatically."
        } else {
            statusMessage = "New \(category) task created. Edit details — changes save automatically."
        }
    }

    func duplicateSelectedTask() {
        guard let selectedTaskID,
              let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) else {
            return
        }

        var copy = tasks[index]
        copy.id = UUID()
        copy.item = "\(copy.item) Copy"
        tasks.insert(copy, at: index + 1)
        self.selectedTaskID = copy.id
        writeLocalCacheOnly()
        Task { await upsertTaskToServer(copy) }
    }


    func addPhotoToSelectedTask() {
        guard let selectedTaskID,
              let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) else {
            statusMessage = "Select a task before adding a photo."
            return
        }

        guard let fileName = TaskPhotoStore.chooseAndCopyPhoto(into: selectedTaskID) else {
            statusMessage = "No photo added."
            return
        }

        tasks[index].photoFileNames.append(fileName)
        writeLocalCacheOnly()
        Task { await upsertTaskToServer(tasks[index]) }
        statusMessage = "Photo added."
    }

    func removePhotoFromSelectedTask(_ fileName: String) {
        guard let selectedTaskID,
              let index = tasks.firstIndex(where: { $0.id == selectedTaskID }) else {
            return
        }

        TaskPhotoStore.removePhoto(taskID: selectedTaskID, fileName: fileName)
        tasks[index].photoFileNames.removeAll { $0 == fileName }
        writeLocalCacheOnly()
        Task { await upsertTaskToServer(tasks[index]) }
        statusMessage = "Photo removed."
    }

    func revealPhoto(_ fileName: String) {
        guard let selectedTaskID else { return }
        let url = TaskPhotoStore.url(taskID: selectedTaskID, fileName: fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func deleteSelectedTask() {
        guard let selectedTaskID else {
            return
        }

        let removedID = selectedTaskID
        TaskPhotoStore.removeAllPhotos(taskID: removedID)
        tasks.removeAll { $0.id == removedID }
        self.selectedTaskID = tasks.first?.id
        writeLocalCacheOnly()
        Task { @MainActor in
            do {
                _ = try await apiClient.deleteTask(id: removedID)
                isOnline = true
                lastSyncAt = Date()
                statusMessage = "Deleted task"
            } catch {
                isOnline = false
                statusMessage = "Deleted on Mac; server: \(error.localizedDescription)"
            }
        }
    }

    func importKnownIntelCSV(fromPull: Bool = false) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/PropertyManagerApp/imports/maintenance_log_from_intelmini.csv")

        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Intel CSV not found at expected path"
            return
        }

        importOpenClawCSV(from: url, preserveLocalOnlyTasks: true, markDirty: !fromPull)
    }

    func runLatestPullScript() {
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/PropertyManagerApp/scripts/refresh-from-postgres.sh")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            statusMessage = "Refresh from Postgres script was not found."
            return
        }

        statusMessage = "Refreshing from Postgres..."

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = scriptURL
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanError = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.importKnownIntelCSV(fromPull: true)
                        self.lastPullAt = Date()
                        self.hasLocalChanges = false
                        self.persistSyncState()
                        self.statusMessage = """
                        Refresh from Postgres complete. Local cache updated.

                        Loaded:
                        \(self.tasks.count) tasks

                        Shared OpenClaw fields updated. Mac-only how-to text kept.
                        """
                    } else {
                        self.statusMessage = """
                        Refresh from Postgres failed.

                        Script output:
                        \(cleanOutput.isEmpty ? "No standard output." : cleanOutput)

                        Error output:
                        \(cleanError.isEmpty ? "No error output." : cleanError)
                        """
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Refresh from Postgres could not run: \(error.localizedDescription)"
                }
            }
        }
    }

    func importFromCSVPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import OpenClaw PropertyManager CSV"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let response = panel.runModal()

        guard response == .OK, let url = panel.url else {
            statusMessage = "Import canceled"
            return
        }

        importOpenClawCSV(from: url, preserveLocalOnlyTasks: true, markDirty: true)
    }

    func publishToIntelMini() {
        save(markDirty: false)

        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/PropertyManagerApp/scripts/save-to-postgres.sh")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            statusMessage = "Save to Postgres script was not found."
            return
        }

        statusMessage = "Saving to Postgres..."

        let csvPath = stagingCSVURL.path

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = scriptURL
            process.arguments = [csvPath]
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanError = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.hasLocalChanges = false
                        self.lastPublishAt = Date()
                        self.persistSyncState()
                        self.statusMessage = self.pushToIntelMiniSuccessMessage(from: cleanOutput)
                    } else {
                        self.statusMessage = """
                        Publish failed.

                        Script output:
                        \(cleanOutput.isEmpty ? "No standard output." : cleanOutput)

                        Error output:
                        \(cleanError.isEmpty ? "No error output." : cleanError)
                        """
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Publish could not run: \(error.localizedDescription)"
                }
            }
        }
    }

    private func writeStagingCSV() throws {
        var lines: [String] = []
        lines.append("area,item,last_done,warning_days,critical_days")

        for task in tasks where task.isActive {
            let columns = [
                task.area,
                task.item,
                DateHelper.isoDate(task.lastDone),
                String(task.warningDays),
                String(task.criticalDays)
            ]
            lines.append(columns.map(csvEscape).joined(separator: ","))
        }

        let csv = lines.joined(separator: "\n") + "\n"
        try csv.write(to: stagingCSVURL, atomically: true, encoding: .utf8)
    }

    func openDataFolder() {
        let folder = saveURL.deletingLastPathComponent()
        NSWorkspace.shared.open(folder)
        statusMessage = "Opened local data folder"
    }


    func resolveManualPDF(named rawName: String) -> URL? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let candidates = [
            appSupportFolder.appendingPathComponent("manuals", isDirectory: true).appendingPathComponent(name),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Development/PropertyManagerApp/manuals")
                .appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func pickManualPDF() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Manufacturer Manual PDF"
        panel.message = "Select the handbook PDF to fill How-To for this task only."
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/PropertyManagerApp/manuals")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func fillHowToFromManual(taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            statusMessage = "Select a task before filling How-To."
            return
        }

        var pdfURL = resolveManualPDF(named: tasks[index].sourceManualName)
        if pdfURL == nil {
            guard let picked = pickManualPDF() else {
                statusMessage = "How-To fill canceled — no manual selected. Task stays Owner-added."
                tasks[index].origin = .owner
                save(markDirty: true)
                return
            }
            archiveManualPDF(picked)
            pdfURL = picked
            tasks[index].sourceManualName = picked.lastPathComponent
        }

        guard let pdfURL else { return }

        statusMessage = """
        Filling How-To from \(pdfURL.lastPathComponent) via Ollama (\(ManufacturerManualImporter.preferredModel))…
        """

        let area = tasks[index].area
        let item = tasks[index].item
        let description = tasks[index].taskDescription
        let manualName = pdfURL.lastPathComponent

        Task {
            do {
                let result = try await ManufacturerManualImporter.fillHowTo(
                    forTaskArea: area,
                    item: item,
                    taskDescription: description,
                    from: pdfURL
                )
                await MainActor.run {
                    guard let idx = self.tasks.firstIndex(where: { $0.id == taskID }) else { return }
                    if result.found {
                        self.tasks[idx].responseInstructions = result.responseInstructions
                        self.tasks[idx].origin = .manufacturer
                        self.tasks[idx].sourceManualName = manualName
                        if !result.manufacturer.isEmpty {
                            self.tasks[idx].manufacturer = result.manufacturer
                        }
                        self.save(markDirty: true)
                        self.statusMessage = "How-To filled from manufacturer manual \(manualName)."
                    } else {
                        self.tasks[idx].origin = .owner
                        let title = TaskTitle.displayFullTitle(
                            area: self.tasks[idx].area,
                            item: self.tasks[idx].item,
                            assetId: self.tasks[idx].assetId,
                            assets: self.assets
                        )
                        self.tasks[idx].responseInstructions = """
                        1. Inspect \(title).

                        2. Complete the required maintenance.

                        3. Record readings, supplies used, or problems found.

                        4. Add follow-up notes if another task is needed.

                        5. Mark the task complete.
                        """
                        self.save(markDirty: true)
                        self.statusMessage = "No manufacturer procedure found in \(manualName) for this task — marked Owner-added."
                    }
                }
            } catch {
                await MainActor.run {
                    guard let idx = self.tasks.firstIndex(where: { $0.id == taskID }) else { return }
                    self.tasks[idx].origin = .owner
                    self.save(markDirty: true)
                    self.statusMessage = "How-To fill failed: \(error.localizedDescription). Marked Owner-added."
                }
            }
        }
    }

    func archiveManualPDF(_ url: URL) {
        let manuals = appSupportFolder.appendingPathComponent("manuals", isDirectory: true)
        try? FileManager.default.createDirectory(at: manuals, withIntermediateDirectories: true)
        let destination = manuals.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    func importManualDrafts(_ drafts: [ManualImportDraft]) {
        let selected = drafts.filter(\.selected)
        guard !selected.isEmpty else {
            statusMessage = "No manufacturer tasks selected."
            return
        }

        let newTasks = selected.map {
            $0.asMaintenanceTask(verificationStatus: .userAccepted)
        }
        tasks.insert(contentsOf: newTasks, at: 0)
        selectedTaskID = newTasks.first?.id
        save(markDirty: true)
        statusMessage = """
        Imported \(newTasks.count) manufacturer task(s) from manual.

        Review how-to, parts, and tools, then Publish when ready.
        """
    }

    func chooseManualPDFAndImport(onDrafts: @escaping ([ManualImportDraft], String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import Maintenance Tasks from Manufacturer PDF"
        panel.message = "Choose an owner's / service manual PDF. Local Ollama will propose tasks for review."
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/PropertyManagerApp/manuals")

        guard panel.runModal() == .OK, let url = panel.url else {
            statusMessage = "Manual PDF import canceled"
            return
        }

        archiveManualPDF(url)
        statusMessage = """
        Reading manual and asking local Ollama (\(ManufacturerManualImporter.preferredModel))…

        File: \(url.lastPathComponent)
        """

        Task {
            do {
                let result = try await ManufacturerManualImporter.importDrafts(from: url)
                await MainActor.run {
                    onDrafts(result.drafts, result.manufacturer)
                    statusMessage = """
                    Proposed \(result.drafts.count) manufacturer task(s).

                    Review and import the ones you want.
                    """
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Manual PDF import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Import manufacturer tasks from a public manual TOC/page URL.
    /// Does **not** archive a full manual copy — links + short excerpts + provenance only.
    func importFromURL(_ urlString: String, onDrafts: @escaping ([ManualImportDraft], String) -> Void) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Paste a manufacturer manual URL first."
            return
        }

        statusMessage = """
        Fetching manual page(s) and asking local Ollama (\(ManufacturerManualImporter.preferredModel))…

        URL: \(trimmed)
        """

        Task {
            do {
                let result = try await URLManualImporter.importDrafts(from: trimmed)
                await MainActor.run {
                    onDrafts(result.drafts, result.manufacturer)
                    statusMessage = """
                    Proposed \(result.drafts.count) manufacturer task(s) from URL.

                    Review provenance and import the ones you want.
                    """
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Manual URL import failed: \(error.localizedDescription)"
                }
            }
        }
    }


    func dashboardBackupPlaceholder() {
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/PropertyManagerApp/scripts/dashboard_backup.sh")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            statusMessage = "Dashboard backup script was not found."
            return
        }

        statusMessage = "Starting dashboard backup..."

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = scriptURL
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanError = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                let message: String

                if process.terminationStatus == 0 {
                    message = Self.dashboardBackupSuccessMessage(from: cleanOutput)
                } else {
                    message = cleanError.isEmpty ? "Dashboard backup failed." : cleanError
                }

                DispatchQueue.main.async {
                    self.statusMessage = message
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Dashboard backup could not run: \(error.localizedDescription)"
                }
            }
        }
    }

    private nonisolated static func dashboardBackupSuccessMessage(from output: String) -> String {
        guard !output.isEmpty else {
            return "Backup completed successfully."
        }

        if let backupPath = Self.dashboardBackupPath(from: output) {
            let backupFolder = URL(fileURLWithPath: backupPath).lastPathComponent

            return """
            Backup completed successfully.

            Backup folder:
            \(backupFolder)

            Full path:
            \(backupPath)

            Full script output:
            \(output)
            """
        }

        return """
        Backup completed successfully.

        Full script output:
        \(output)
        """
    }

    private nonisolated static func dashboardBackupPath(from output: String) -> String? {
        let pathPrefix = "/home/gravesab/ai/projects/openclaw/tools/dashboard/backups/propertymanager_app_backups/"

        for token in output.components(separatedBy: .whitespacesAndNewlines).reversed() {
            let cleanedToken = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;()[]{}<>\"'"))

            if cleanedToken.hasPrefix(pathPrefix),
               cleanedToken.contains("/backup-") {
                return cleanedToken
            }
        }

        return nil
    }

    private func pushToIntelMiniSuccessMessage(from output: String) -> String {
        let verifiedLines = verifiedLineCount(from: output)

        return """
        Push complete.

        Intel mini backup created.
        maintenance_log.csv updated.
        Verified \(verifiedLines ?? "the pushed file") lines.
        """
    }

    private func verifiedLineCount(from output: String) -> String? {
        let lines = output.components(separatedBy: .newlines)

        for index in lines.indices {
            guard lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == "Line count:",
                  lines.index(after: index) < lines.endIndex else {
                continue
            }

            let nextLine = lines[lines.index(after: index)]
            let firstToken = nextLine
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .first

            if let firstToken {
                return String(firstToken)
            }
        }

        return nil
    }

    func importOpenClawCSV(
        from url: URL,
        preserveLocalOnlyTasks: Bool = true,
        markDirty: Bool = true
    ) {
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let rows = parseCSV(raw)

            guard rows.count >= 2 else {
                statusMessage = "CSV has no task rows"
                return
            }

            let header = rows[0].map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }

            guard header.count >= 5,
                  header[0] == "area",
                  header[1] == "item",
                  header[2] == "last_done",
                  header[3] == "warning_days",
                  header[4] == "critical_days" else {
                statusMessage = "Wrong CSV format. Expected area,item,last_done,warning_days,critical_days"
                return
            }

            var existingByKey: [String: MaintenanceTask] = [:]

            for task in tasks {
                existingByKey[taskKey(area: task.area, item: task.item)] = task
            }

            var importedKeys = Set<String>()
            var imported: [MaintenanceTask] = []

            for row in rows.dropFirst() {
                guard row.count >= 5 else {
                    continue
                }

                let area = clean(row[0])
                let item = clean(row[1])
                let lastDoneText = clean(row[2])
                let warningDays = Int(clean(row[3])) ?? 30
                let criticalDays = Int(clean(row[4])) ?? max(warningDays * 2, warningDays)

                guard !area.isEmpty, !item.isEmpty else {
                    continue
                }

                let lastDone = parseDate(lastDoneText) ?? Date()
                let nextDue = addDays(lastDone, warningDays)
                let key = taskKey(area: area, item: item)
                importedKeys.insert(key)

                if var existing = existingByKey[key] {
                    // Shared OpenClaw columns only — keep Mac-only rich fields.
                    existing.area = area
                    existing.item = item
                    existing.warningDays = warningDays
                    existing.criticalDays = criticalDays
                    existing.lastDone = lastDone
                    existing.nextDue = nextDue
                    imported.append(existing)
                } else {
                    let category = categoryFromArea(area)
                    let frequency = frequencyFromWarningDays(warningDays)
                    let priority = priorityFromDates(
                        lastDone: lastDone,
                        warningDays: warningDays,
                        criticalDays: criticalDays
                    )
                    imported.append(
                        MaintenanceTask(
                            area: area,
                            item: item,
                            category: category,
                            priority: priority,
                            frequency: frequency,
                            taskDescription: TaskTitle.canonicalItem(assetName: area, title: item),
                            responseInstructions: defaultResponse(forArea: area, item: item),
                            suppliesNeeded: defaultSupplies(forArea: area, item: item),
                            notes: "Imported from OpenClaw. Warning days: \(warningDays). Critical days: \(criticalDays).",
                            resultNotes: "",
                            estimatedMinutes: estimatedMinutes(forArea: area, item: item),
                            warningDays: warningDays,
                            criticalDays: criticalDays,
                            lastDone: lastDone,
                            nextDue: nextDue,
                            sendTelegramUpdate: true,
                            includeInDailyBriefing: true,
                            alertIfOverdue: true,
                            isActive: true
                        )
                    )
                }
            }

            guard !imported.isEmpty else {
                statusMessage = "No usable OpenClaw tasks found in CSV"
                return
            }

            if preserveLocalOnlyTasks {
                for task in tasks {
                    let key = taskKey(area: task.area, item: task.item)
                    if !importedKeys.contains(key) {
                        imported.append(task)
                    }
                }
            }

            tasks = imported
            selectedTaskID = tasks.first?.id
            save(markDirty: markDirty)
            statusMessage = "Imported \(imported.count) tasks (shared fields from OpenClaw)"
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportOpenClawCSV(to url: URL) {
        do {
            var lines: [String] = []
            lines.append("area,item,last_done,warning_days,critical_days")

            for task in tasks {
                let columns = [
                    task.area,
                    task.item,
                    DateHelper.isoDate(task.lastDone),
                    String(task.warningDays),
                    String(task.criticalDays)
                ]

                lines.append(columns.map(csvEscape).joined(separator: ","))
            }

            let csv = lines.joined(separator: "\n") + "\n"
            try csv.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = """
            Staging CSV written.

            Saved to Application Support staging_publish.csv
            """
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var insideQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                if insideQuotes,
                   index + 1 < characters.count,
                   characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    insideQuotes.toggle()
                }
            } else if character == "," && !insideQuotes {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r") && !insideQuotes {
                if character == "\r",
                   index + 1 < characters.count,
                   characters[index + 1] == "\n" {
                    index += 1
                }

                row.append(field)
                field = ""

                if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    rows.append(row)
                }

                row = []
            } else {
                field.append(character)
            }

            index += 1
        }

        row.append(field)

        if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            rows.append(row)
        }

        return rows
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        let needsQuotes = escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") || escaped.contains("\r")

        if needsQuotes {
            return "\"\(escaped)\""
        }

        return escaped
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func taskKey(area: String, item: String) -> String {
        "\(clean(area).lowercased())|\(clean(item).lowercased())"
    }

    private func backupUnreadableSaveFile() {
        let url = saveURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("maintenance_tasks.unreadable.\(formatter.string(from: Date())).json")

        try? FileManager.default.copyItem(at: url, to: backupURL)
    }

    private func parseDate(_ text: String) -> Date? {
        let trimmed = clean(text)

        let formats = [
            "yyyy-MM-dd",
            "yyyy-MM-dd HH:mm:ss",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "MMM d, yyyy",
            "MMMM d, yyyy"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format

            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    private func addDays(_ date: Date, _ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    private func categoryFromArea(_ area: String) -> String {
        let lower = area.lowercased()

        if lower.contains("pool") {
            return "Pool"
        }

        if lower.contains("hot") || lower.contains("tub") || lower.contains("spa") {
            return "Hot Tub"
        }

        if lower.contains("tractor") || lower.contains("mower") || lower.contains("pump") || lower.contains("equipment") {
            return "Equipment"
        }

        if lower.contains("fence") || lower.contains("gate") || lower.contains("property") || lower.contains("road") {
            return "Property"
        }

        if lower.contains("trail") || lower.contains("ground") || lower.contains("yard") || lower.contains("land") {
            return "Grounds"
        }

        if lower.contains("safety") || lower.contains("fire") || lower.contains("smoke") {
            return "Safety"
        }

        return "House"
    }

    private func frequencyFromWarningDays(_ days: Int) -> TaskFrequency {
        if days <= 1 {
            return .daily
        }

        if days <= 7 {
            return .weekly
        }

        if days <= 14 {
            return .biweekly
        }

        if days <= 45 {
            return .monthly
        }

        if days <= 120 {
            return .quarterly
        }

        return .yearly
    }

    private func priorityFromDates(lastDone: Date, warningDays: Int, criticalDays: Int) -> TaskPriority {
        let today = Calendar.current.startOfDay(for: Date())
        let warningDate = Calendar.current.startOfDay(for: addDays(lastDone, warningDays))
        let criticalDate = Calendar.current.startOfDay(for: addDays(lastDone, criticalDays))

        if today >= criticalDate {
            return .high
        }

        if today >= warningDate {
            return .medium
        }

        return .low
    }

    private func estimatedMinutes(forArea area: String, item: String) -> Int {
        let combined = "\(area) \(item)".lowercased()

        if combined.contains("water test") {
            return 15
        }

        if combined.contains("filter") {
            return 30
        }

        if combined.contains("drain") {
            return 60
        }

        if combined.contains("oil") {
            return 30
        }

        if combined.contains("grease") {
            return 20
        }

        if combined.contains("inspection") {
            return 30
        }

        return 30
    }

    private func defaultSupplies(forArea area: String, item: String) -> String {
        let combined = "\(area) \(item)".lowercased()

        if combined.contains("pool") || combined.contains("hot tub") {
            return "Test strips, gloves, hose, chemicals as needed"
        }

        if combined.contains("tractor") {
            return "Gloves, shop rags, grease gun, oil or fluids as needed"
        }

        return ""
    }

    private func defaultResponse(forArea area: String, item: String) -> String {
        let combined = "\(area) \(item)".lowercased()

        if combined.contains("pool") && combined.contains("water test") {
            return """
            1. Collect a pool water sample from elbow depth with the pump running.

            2. Test pH, chlorine, alkalinity, and other required levels.

            3. Add chemicals only as needed.

            4. Run the pump after adding chemicals.

            5. Record readings and mark the task complete.
            """
        }

        if combined.contains("hot tub") && combined.contains("water test") {
            return """
            1. Collect a hot tub water sample.

            2. Test sanitizer, pH, and alkalinity.

            3. Adjust chemicals as needed.

            4. Run jets to circulate the water.

            5. Record readings and mark the task complete.
            """
        }

        if combined.contains("filter") {
            return """
            1. Turn off equipment if needed.

            2. Remove the filter or prepare for backwash.

            3. Clean, rinse, or backwash according to equipment needs.

            4. Reinstall or reset equipment.

            5. Check for normal flow and record completion.
            """
        }

        if combined.contains("tractor") {
            return """
            1. Park tractor safely on level ground.

            2. Inspect the required item.

            3. Add fluid, grease, adjust, or repair as needed.

            4. Record any issue that needs follow-up.

            5. Mark the task complete.
            """
        }

        return """
        1. Inspect the area or equipment.

        2. Complete the maintenance task.

        3. Record any readings, supplies used, or issues found.

        4. Add follow-up notes if needed.

        5. Mark the task complete.
        """
    }

    static func sampleTasks() -> [MaintenanceTask] {
        let today = Date()

        return [
            MaintenanceTask(
                area: "Pool",
                item: "Water test",
                category: "Pool",
                priority: .medium,
                frequency: .weekly,
                taskDescription: "Pool: Water test",
                responseInstructions: """
                1. Collect a pool water sample from elbow depth.

                2. Test pH, chlorine, and alkalinity.

                3. Adjust chemicals as needed.

                4. Record readings and mark complete.
                """,
                suppliesNeeded: "Test strips, gloves, pool chemicals",
                notes: "Sample task. Import your OpenClaw CSV to replace these.",
                estimatedMinutes: 15,
                warningDays: 7,
                criticalDays: 14,
                lastDone: Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today,
                nextDue: today
            ),
            MaintenanceTask(
                area: "Hot Tub",
                item: "Filter cleaning",
                category: "Hot Tub",
                priority: .low,
                frequency: .monthly,
                taskDescription: "Hot Tub: Filter cleaning",
                responseInstructions: """
                1. Turn off jets.

                2. Remove filter.

                3. Rinse filter with hose.

                4. Reinstall filter and check flow.
                """,
                suppliesNeeded: "Hose, filter cleaner",
                notes: "Sample task.",
                estimatedMinutes: 30,
                warningDays: 30,
                criticalDays: 45,
                lastDone: Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today,
                nextDue: Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
            )
        ]
    }
}

struct ContentView: View {
    @ObservedObject var store: MaintenanceStore
    @State private var searchText = ""
    @State private var selectedOriginFilter: TaskOrigin? = nil
    @State private var selectedCategoryFilter: String?
    @State private var manualDrafts: [ManualImportDraft] = []
    @State private var showingManualImportReview = false
    @State private var showingURLImportSheet = false
    @State private var manualImportManufacturer = ""

    var filteredTasks: [MaintenanceTask] {
        var result = store.tasks

        if let selectedOriginFilter {
            result = result.filter { $0.origin == selectedOriginFilter }
        }

        if let selectedCategoryFilter {
            result = result.filter { $0.category == selectedCategoryFilter }
        }

        let cleanSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanSearch.isEmpty {
            result = result.filter {
                let group = TaskTitle.displayAssetName(area: $0.area, assetId: $0.assetId, assets: store.assets)
                let display = TaskTitle.displayItemTitle(item: $0.item, group: group)
                return $0.area.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.item.localizedCaseInsensitiveContains(cleanSearch) ||
                group.localizedCaseInsensitiveContains(cleanSearch) ||
                display.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.taskDescription.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.manufacturer.localizedCaseInsensitiveContains(cleanSearch) ||
                $0.sourceManualName.localizedCaseInsensitiveContains(cleanSearch)
            }
        }

        return result
    }

    var groupedTasks: [TaskGroupSection] {
        var buckets: [String: [MaintenanceTask]] = [:]
        for task in filteredTasks {
            let key = TaskTitle.displayAssetName(area: task.area, assetId: task.assetId, assets: store.assets)
            buckets[key, default: []].append(task)
        }
        return buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                let tasks = (buckets[name] ?? []).sorted {
                    let l = TaskTitle.displayItemTitle(item: $0.item, group: name)
                    let r = TaskTitle.displayItemTitle(item: $1.item, group: name)
                    return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                }
                return TaskGroupSection(name: name, tasks: tasks)
            }
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                tasks: store.tasks,
                isOnline: store.isOnline,
                lastSyncAt: store.lastSyncAt,
                apiBaseURL: Binding(
                    get: { store.apiBaseURL },
                    set: { store.apiBaseURL = $0 }
                ),
                apiKey: Binding(
                    get: { store.apiKey },
                    set: { store.apiKey = $0 }
                ),
                operatorPIN: Binding(
                    get: { store.operatorPIN },
                    set: { store.operatorPIN = $0 }
                ),
                refreshAction: { Task { await store.refreshFromServer() } },
                importManualAction: {
                    store.chooseManualPDFAndImport { drafts, manufacturer in
                        manualDrafts = drafts
                        manualImportManufacturer = manufacturer
                        showingManualImportReview = true
                    }
                },
                importFromURLAction: {
                    showingURLImportSheet = true
                },
                statusMessage: store.statusMessage,
                showAssetsPanel: store.showAssetsPanel,
                toggleAssetsAction: { store.showAssetsPanel.toggle() },
                calendarPushAction: { Task { await store.pushToCalendar() } },
                deleteDevCalendarEventsAction: { Task { await store.deleteDevCalendarEvents() } },
                calendarSyncMessage: store.calendarSyncMessage,
                isSyncingCalendar: store.isSyncingCalendar
            )

            Divider()

            Group {
            if store.showAssetsPanel {
                MacAssetsPanel(store: store)
            } else {
            VStack(spacing: 0) {
                TaskListHeaderView(
                    searchText: $searchText,
                    selectedOriginFilter: $selectedOriginFilter,
                    selectedCategoryFilter: $selectedCategoryFilter,
                    categories: store.categories,
                    taskCountForCategory: { name in
                        store.activeTaskCount(inCategoryNamed: name)
                    },
                    addAction: {
                        store.addTask(category: selectedCategoryFilter, kind: .scheduled)
                    },
                    addWorkRequestAction: {
                        store.addTask(category: selectedCategoryFilter, kind: .workRequest)
                    },
                    addCategoryAction: { name in
                        _ = store.addCategory(named: name)
                    },
                    deleteCategoryAction: { category, reassignTo in
                        _ = store.deleteCategory(category, reassignTo: reassignTo)
                    }
                )

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groupedTasks) { section in
                            Text(section.name)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(section.tasks) { task in
                                TaskRowView(
                                    task: task,
                                    groupName: section.name,
                                    isSelected: task.id == store.selectedTaskID
                                )
                                .onTapGesture {
                                    store.selectedTaskID = task.id
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .frame(width: 330)
            }
            }

            Divider()

            editorArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Window is already visible; refresh offline cache first, then assets.
            await store.refreshFromServer()
            await store.refreshAssets()
            let envPush = ProcessInfo.processInfo.environment["PROPERTYMANAGER_AUTOPUSH_CALENDAR"] == "1"
            let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent("pm-autopush-calendar")
            let filePush = FileManager.default.fileExists(atPath: sentinel.path)
            if envPush || filePush {
                await store.pushToCalendar()
                NSLog("[CalendarSync] autopush status=%@", store.calendarSyncMessage as NSString)
                try? FileManager.default.removeItem(at: sentinel)
            }
        }
        .sheet(isPresented: $showingManualImportReview) {
            ManualImportReviewSheet(
                manufacturer: manualImportManufacturer,
                drafts: $manualDrafts,
                onCancel: { showingManualImportReview = false },
                onImport: {
                    store.importManualDrafts(manualDrafts)
                    showingManualImportReview = false
                }
            )
            .frame(minWidth: 780, minHeight: 560)
        }
        .sheet(isPresented: $showingURLImportSheet) {
            URLManualImportSheet(
                isPresented: $showingURLImportSheet,
                statusMessage: store.statusMessage,
                onFetch: { urlString in
                    store.importFromURL(urlString) { drafts, manufacturer in
                        manualDrafts = drafts
                        manualImportManufacturer = manufacturer
                        showingURLImportSheet = false
                        showingManualImportReview = true
                    }
                }
            )
            .frame(minWidth: 520, minHeight: 260)
        }
    }

    @ViewBuilder
    var editorArea: some View {
        if let selectedTaskID = store.selectedTaskID,
           let index = store.tasks.firstIndex(where: { $0.id == selectedTaskID }) {
            TaskEditorView(
                task: $store.tasks[index],
                categories: store.categories,
                assets: store.assets,
                autosaveAction: { task in store.scheduleAutosave(task) },
                saveAction: { Task { await store.saveSelectedTask() } },
                completeAction: { Task { await store.completeSelectedTask() } },
                duplicateAction: store.duplicateSelectedTask,
                deleteAction: store.deleteSelectedTask,
                addPhotoAction: store.addPhotoToSelectedTask,
                removePhotoAction: store.removePhotoFromSelectedTask,
                revealPhotoAction: store.revealPhoto,
                fillHowToAction: {
                    store.fillHowToFromManual(taskID: selectedTaskID)
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("No task selected")
                    .font(.title2)
                    .fontWeight(.semibold)

                Button("Add Maintenance Task") {
                    store.addTask(category: selectedCategoryFilter)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SidebarView: View {
    let tasks: [MaintenanceTask]
    let isOnline: Bool
    let lastSyncAt: Date?
    @Binding var apiBaseURL: String
    @Binding var apiKey: String
    @Binding var operatorPIN: String
    let refreshAction: () -> Void
    let importManualAction: () -> Void
    let importFromURLAction: () -> Void
    let statusMessage: String
    let showAssetsPanel: Bool
    let toggleAssetsAction: () -> Void
    let calendarPushAction: () -> Void
    let deleteDevCalendarEventsAction: () -> Void
    let calendarSyncMessage: String
    let isSyncingCalendar: Bool
    @AppStorage("propertyManager.appearance") private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("propertyManager.calendarStartHour") private var calendarStartHour: Int = 8
    @AppStorage("propertyManager.calendarStartMinute") private var calendarStartMinute: Int = 0
    @AppStorage("propertyManager.calendarSyncEnv") private var calendarSyncEnvRaw: String = SyncEnv.dev.rawValue

    private var briefingCounts: BriefingCounts {
        BriefingCounts(tasks: tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "house.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.blue)
                    .frame(width: 60, height: 60)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("Property Manager")
                    .font(.title3)
                    .fontWeight(.bold)

                Text("RedBud Ranch")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            CentralTimeCard()

            ConnectionStatusCard(
                isOnline: isOnline,
                lastSyncAt: lastSyncAt,
                apiBaseURL: $apiBaseURL,
                apiKey: $apiKey,
                operatorPIN: $operatorPIN
            )

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    refreshAction()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    importManualAction()
                } label: {
                    Label("Import from Manual PDF", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    importFromURLAction()
                } label: {
                    Label("Import from URL", systemImage: "link")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ActionResultView(message: statusMessage)

                Button {
                    toggleAssetsAction()
                } label: {
                    Label(showAssetsPanel ? "Show Tasks" : "Show Assets", systemImage: "gauge.with.dots.needle.67percent")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // MARK: Calendar sync section
            VStack(alignment: .leading, spacing: 8) {
                Label("OpenClaw Calendar", systemImage: "calendar")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.purple)

                // Start time and env picker on one row
                HStack(spacing: 6) {
                    Text("Start")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("Hour", selection: $calendarStartHour) {
                        ForEach(Array(5...21), id: \.self) { h in
                            Text(String(format: "%d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 68)
                    .font(.caption2)
                    Spacer()
                    Picker("Env", selection: $calendarSyncEnvRaw) {
                        ForEach(SyncEnv.allCases) { env in
                            Text(env.label).tag(env.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 56)
                    .font(.caption2)
                }

                Button {
                    calendarPushAction()
                } label: {
                    Label(
                        isSyncingCalendar ? "Working..." : "Push today's due tasks to OpenClaw",
                        systemImage: "calendar.badge.plus"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isSyncingCalendar)

                // Delete DEV events — only shown when env is DEV so it can't
                // accidentally nuke prod events after cutover.
                if calendarSyncEnvRaw == SyncEnv.dev.rawValue {
                    Button(role: .destructive) {
                        deleteDevCalendarEventsAction()
                    } label: {
                        Label("Delete DEV PM calendar events", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isSyncingCalendar)
                }

                if !calendarSyncMessage.isEmpty {
                    Text(calendarSyncMessage)
                        .font(.caption2)
                        .foregroundStyle(
                            calendarSyncMessage.hasPrefix("Calendar:") || calendarSyncMessage.hasPrefix("EventKit")
                                ? .red : .secondary
                        )
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(calendarSyncMessage)
                }
            }
            .padding(10)
            .background(Color.purple.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))


            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Daily Briefing", systemImage: "sun.max.fill")
                    .foregroundStyle(.orange)
                    .fontWeight(.semibold)

                HStack {
                    Text("\(briefingCounts.tasksToday)")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Tasks Today")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(briefingCounts.overdue)")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                    Text("Overdue")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("\(briefingCounts.dueThisWeek)")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Due This Week")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)
        }
        .padding()
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

struct ConnectionStatusCard: View {
    let isOnline: Bool
    let lastSyncAt: Date?
    @Binding var apiBaseURL: String
    @Binding var apiKey: String
    @Binding var operatorPIN: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(isOnline ? "Online" : "Offline", systemImage: isOnline ? "checkmark.circle.fill" : "wifi.slash")
                .font(.caption)
                .foregroundStyle(isOnline ? Color.green : Color.orange)

            if let lastSyncAt {
                Text("Updated \(lastSyncAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not synced yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("API Base URL")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("http://host:5062", text: $apiBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)

            Text("API Key")
                .font(.caption2)
                .foregroundStyle(.secondary)
            SecureField("PROPERTYMANAGER_API_KEY", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)

            Text("Operator PIN")
                .font(.caption2)
                .foregroundStyle(.secondary)
            SecureField("PROPERTYMANAGER_OPERATOR_PIN", text: $operatorPIN)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)

            Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Auth: missing API key" : "Auth: API key set")
                .font(.caption2)
                .foregroundStyle(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.orange : Color.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(isOnline ? 0.10 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ActionResultView: View {
    let message: String
    private var displayMessage: Binding<String> {
        .constant(message)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Action Result")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            TextEditor(text: displayMessage)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .frame(height: 140, alignment: .topLeading)
                .padding(6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18))
            )
        }
        .padding(.top, 4)
    }
}

struct CentralTimeCard: View {
    @State private var now = Date()

    private let timer = Timer.publish(
        every: 30,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Central Time", systemImage: "clock")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.blue)

            Text(DateHelper.centralLongDate(now))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(DateHelper.centralClockTime(now))
                .font(.title3)
                .fontWeight(.bold)

            Text("America/Chicago")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(timer) { value in
            now = value
        }
    }
}

struct WorkflowCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Safe Workflow", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 5) {
                Text("1. Open the app")
                Text("2. Edit a task")
                Text("3. Changes save automatically")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("Mac and iPhone share the same task list.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SidebarItem: View {
    let icon: String
    let title: String
    let selected: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 26)

            Text(title)
                .fontWeight(selected ? .semibold : .regular)

            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(selected ? Color.blue.opacity(0.14) : Color.clear)
        .foregroundStyle(selected ? Color.blue : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct TaskListHeaderView: View {
    @Binding var searchText: String
    @Binding var selectedOriginFilter: TaskOrigin?
    @Binding var selectedCategoryFilter: String?
    let categories: [CategoryDefinition]
    let taskCountForCategory: (String) -> Int
    let addAction: () -> Void
    let addWorkRequestAction: () -> Void
    let addCategoryAction: (String) -> Void
    let deleteCategoryAction: (CategoryDefinition, String?) -> Void

    @State private var showingAddCategory = false
    @State private var showingDeleteCategory = false
    @State private var showingReassignSheet = false
    @State private var categoryPendingDelete: CategoryDefinition?
    @State private var reassignToName = "House"
    @State private var newCategoryName = ""

    private var deletableCategories: [CategoryDefinition] {
        categories
            .filter { $0.name.caseInsensitiveCompare("House") != .orderedSame }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var destinationChoices: [CategoryDefinition] {
        guard let category = categoryPendingDelete else { return [] }
        return categories
            .filter { $0.name.caseInsensitiveCompare(category.name) != .orderedSame }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }


    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search tasks...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(spacing: 8) {
                Button {
                    addAction()
                } label: {
                    Label("New Scheduled Task", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    addWorkRequestAction()
                } label: {
                    Label("New Work Request", systemImage: "wrench.and.screwdriver.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            HStack {
                Spacer(minLength: 0)
                Picker(
                    "Origin",
                    selection: Binding(
                        get: {
                            switch selectedOriginFilter {
                            case .none: return "all"
                            case .some(.manufacturer): return "manufacturer"
                            case .some(.owner): return "owner"
                            }
                        },
                        set: { value in
                            switch value {
                            case "manufacturer": selectedOriginFilter = .manufacturer
                            case "owner": selectedOriginFilter = .owner
                            default: selectedOriginFilter = nil
                            }
                        }
                    )
                ) {
                    Text("All Origins").tag("all")
                    Text("Manufacturer").tag("manufacturer")
                    Text("Owner-added").tag("owner")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Menu {
                    Button {
                        selectedCategoryFilter = nil
                    } label: {
                        if selectedCategoryFilter == nil {
                            Label("All Categories", systemImage: "checkmark")
                        } else {
                            Text("All Categories")
                        }
                    }
                    ForEach(categories) { category in
                        Button {
                            selectedCategoryFilter = category.name
                        } label: {
                            if selectedCategoryFilter == category.name {
                                Label(category.name, systemImage: "checkmark")
                            } else {
                                Text(category.name)
                            }
                        }
                    }
                    if !deletableCategories.isEmpty {
                        Divider()
                        Menu("Delete") {
                            ForEach(deletableCategories) { category in
                                Button("Delete \(category.name)", role: .destructive) {
                                    categoryPendingDelete = category
                                    if taskCountForCategory(category.name) == 0 {
                                        showingDeleteCategory = true
                                    } else {
                                        let destinations = categories.filter {
                                            $0.name.caseInsensitiveCompare(category.name) != .orderedSame
                                        }
                                        if let house = destinations.first(where: {
                                            $0.name.caseInsensitiveCompare("House") == .orderedSame
                                        }) {
                                            reassignToName = house.name
                                        } else {
                                            reassignToName = destinations.first?.name ?? "House"
                                        }
                                        showingReassignSheet = true
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedCategoryFilter ?? "All Categories")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Add Category") {
                    newCategoryName = ""
                    showingAddCategory = true
                }
                .fixedSize()
            }
        }
        .padding()
        .confirmationDialog(
            categoryPendingDelete.map { "Delete \($0.name)?" } ?? "Delete category?",
            isPresented: $showingDeleteCategory,
            titleVisibility: .visible
        ) {
            Button("Delete Category", role: .destructive) {
                guard let category = categoryPendingDelete else { return }
                deleteCategoryAction(category, nil)
                if selectedCategoryFilter?.caseInsensitiveCompare(category.name) == .orderedSame {
                    selectedCategoryFilter = nil
                }
                categoryPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                categoryPendingDelete = nil
            }
        } message: {
            Text("This category has no active tasks and will be removed.")
        }
        .sheet(isPresented: $showingReassignSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Move & Delete")
                    .font(.title2.bold())
                if let category = categoryPendingDelete {
                    Text("\(taskCountForCategory(category.name)) active task(s) use \(category.name). Choose where to move them, then delete the category.")
                        .foregroundStyle(.secondary)
                    Picker("Move tasks to", selection: $reassignToName) {
                        ForEach(destinationChoices) { destination in
                            Text(destination.name).tag(destination.name)
                        }
                    }
                    .labelsHidden()
                }
                HStack {
                    Button("Cancel") {
                        showingReassignSheet = false
                        categoryPendingDelete = nil
                    }
                    Spacer()
                    Button("Move & Delete", role: .destructive) {
                        guard let category = categoryPendingDelete else { return }
                        deleteCategoryAction(category, reassignToName)
                        if selectedCategoryFilter?.caseInsensitiveCompare(category.name) == .orderedSame {
                            selectedCategoryFilter = nil
                        }
                        showingReassignSheet = false
                        categoryPendingDelete = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(reassignToName.isEmpty)
                }
                Spacer()
            }
            .padding(24)
            .frame(width: 460, height: 280)
        }
        .sheet(isPresented: $showingAddCategory) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Category")
                    .font(.title2.bold())
                Text("Examples: Property, Livestock, Irrigation")
                    .foregroundStyle(.secondary)
                TextField("Category name", text: $newCategoryName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showingAddCategory = false }
                    Spacer()
                    Button("Add") {
                        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        addCategoryAction(name)
                        selectedCategoryFilter = name
                        showingAddCategory = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
            }
            .padding(24)
            .frame(width: 420, height: 220)
        }
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(selected ? .semibold : .regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.10))
            .foregroundStyle(selected ? Color.blue : Color.primary)
            .clipShape(Capsule())
    }
}

struct TaskRowView: View {
    let task: MaintenanceTask
    let groupName: String
    let isSelected: Bool

    var body: some View {
        let displayTitle = TaskTitle.displayItemTitle(item: task.item, group: groupName)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: CategoryStyle.icon(for: task.category))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(CategoryStyle.color(for: task.category).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if task.kind == .workRequest {
                        Text("Work Request")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }

                    if !task.photoFileNames.isEmpty {
                        Image(systemName: "camera.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                }

                Text(equipmentSubtitle(for: task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let badge = task.runHoursBadge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(task.overdueMeter == true ? Color.red : (task.dueMeter == true ? Color.orange : Color.secondary))
                }

                                Text("Est. \(task.estimatedMinutes) min  •  Due:\u{00A0}\(DateHelper.isoDate(task.nextDue))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Text(task.origin.label)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(task.origin == .manufacturer ? Color.blue.opacity(0.16) : Color.orange.opacity(0.16))
                    .foregroundStyle(task.origin == .manufacturer ? Color.blue : Color.orange)
                    .clipShape(Capsule())

                Text(statusText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.14))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(isSelected ? Color.blue.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.blue.opacity(0.65) : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }


    private func equipmentSubtitle(for task: MaintenanceTask) -> String {
        var parts: [String] = [task.frequency.rawValue]
        let manufacturer = task.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manufacturer.isEmpty {
            parts.append(manufacturer)
        }
        return parts.joined(separator: " • ")
    }

    var statusText: String {
        let today = Calendar.current.startOfDay(for: Date())
        let due = Calendar.current.startOfDay(for: task.nextDue)
        let critical = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: task.criticalDays, to: task.lastDone) ?? task.nextDue)

        if today >= critical {
            return "Overdue"
        }

        if today >= due {
            return "Due Today"
        }

        return "On Track"
    }

    var statusColor: Color {
        switch statusText {
        case "Overdue":
            return .red
        case "Due Today":
            return .orange
        default:
            return .green
        }
    }
}


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

    fileprivate static func decodeOptionalDecimal(
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
}


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


struct TaskEditorView: View {
    @Binding var task: MaintenanceTask
    let categories: [CategoryDefinition]
    let assets: [MacRanchAsset]

    let autosaveAction: (MaintenanceTask) -> Void
    let saveAction: () -> Void
    let completeAction: () -> Void
    let duplicateAction: () -> Void
    let deleteAction: () -> Void
    let addPhotoAction: () -> Void
    let removePhotoAction: (String) -> Void
    let revealPhotoAction: (String) -> Void
    let fillHowToAction: () -> Void
    @State private var isFillingHowTo = false

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryStrip
                    basicInfoCard
                    photosCard
                    scheduleCard

                    responseCard
                    manufacturerPartsCard
                    responsePreviewCard

                    completionCard
                    historyCard
                    automationCard
                }
                .padding(20)
            }

            Divider()

            bottomActionBar
        }
        .onChange(of: task) { newValue in
            autosaveAction(newValue)
        }
    }

    var editorHeader: some View {
        HStack {
            Image(systemName: CategoryStyle.icon(for: task.category))
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(CategoryStyle.color(for: task.category))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Edit Maintenance Task")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(task.isActive ? "Active" : "Inactive")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(task.isActive ? Color.green.opacity(0.16) : Color.gray.opacity(0.16))
                        .foregroundStyle(task.isActive ? Color.green : Color.gray)
                        .clipShape(Capsule())

                    if task.kind == .workRequest {
                        Text("Work Request")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }

                    Text(task.origin.label)
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(task.origin == .manufacturer ? Color.blue.opacity(0.16) : Color.orange.opacity(0.16))
                        .foregroundStyle(task.origin == .manufacturer ? Color.blue : Color.orange)
                        .clipShape(Capsule())
                }

                Text("Edit fields, then Save to Postgres. Complete marks the job done and advances next due.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                fillHowToAction()
            } label: {
                Label("Fill How-To from Manual", systemImage: "doc.richtext")
            }
            .disabled(isFillingHowTo)
        }
        .padding(20)
    }

    var summaryStrip: some View {
        VStack(spacing: 12) {
            SummaryCard(
                title: "What to do",
                value: task.item,
                subtitle: "\(task.kind.rawValue) • \(task.area) • \(task.category)",
                icon: CategoryStyle.icon(for: task.category),
                color: CategoryStyle.color(for: task.category)
            )

            SummaryCard(
                title: "Warning / Critical",
                value: "\(task.warningDays) / \(task.criticalDays) days",
                subtitle: "Remind / overdue thresholds (shared)",
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )

            SummaryCard(
                title: "Next Due",
                value: DateHelper.isoDate(task.nextDue),
                subtitle: task.frequency.rawValue,
                icon: "calendar",
                color: .green
            )
        }
    }


    var photosCard: some View {
        CardView(title: task.kind == .workRequest ? "Work Request Photos" : "Photos (Mac only)", icon: "camera.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.kind == .workRequest
                     ? "Add a photo of the damage or location (stored on this Mac)."
                     : "Optional photos for this task (stored on this Mac, not published to Intel).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    addPhotoAction()
                } label: {
                    Label("Add Photograph", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                if task.photoFileNames.isEmpty {
                    Text("No photos yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(task.photoFileNames, id: \.self) { fileName in
                        VStack(alignment: .leading, spacing: 8) {
                            TaskPhotoThumbnail(taskID: task.id, fileName: fileName)

                            HStack {
                                Button("Show in Finder") {
                                    revealPhotoAction(fileName)
                                }
                                Spacer()
                                Button("Remove Photo", role: .destructive) {
                                    removePhotoAction(fileName)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    var basicInfoCard: some View {
        CardView(title: "Basic Info", icon: "info.circle") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledField(title: "Category") {
                    Picker(
                        "Category",
                        selection: Binding(
                            get: { task.area },
                            set: { newValue in
                                task.area = newValue
                                task.category = newValue
                            }
                        )
                    ) {
                        ForEach(categories) { category in
                            Text(category.name).tag(category.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }

                Text("Category choices come from Add Category. Area/category stay in sync for Publish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledField(title: "Item (Shared)") {
                    TextField("Item", text: $task.item)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(title: "Type") {
                    Picker("Type", selection: $task.kind) {
                        ForEach(TaskKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }

                HStack(spacing: 16) {
                    LabeledField(title: "Priority") {
                        Picker("Priority", selection: $task.priority) {
                            ForEach(TaskPriority.allCases) { priority in
                                Text(priority.rawValue).tag(priority)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180, alignment: .leading)
                    }

                    LabeledField(title: "Estimated Minutes") {
                        TextField("Minutes", value: $task.estimatedMinutes, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                    }

                    Toggle("Active", isOn: $task.isActive)

                    Spacer()
                }

                LabeledField(title: "Description") {
                    TextField("Description", text: $task.taskDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    var scheduleCard: some View {
        CardView(title: "Schedule (Shared with Intel)", icon: "calendar") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    LabeledField(title: "Frequency") {
                        Picker("Frequency", selection: $task.frequency) {
                            ForEach(TaskFrequency.allCases) { frequency in
                                Text(frequency.rawValue).tag(frequency)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220, alignment: .leading)
                    }

                    LabeledField(title: "Last Done (Shared)") {
                        DatePicker("", selection: $task.lastDone, displayedComponents: [.date])
                            .labelsHidden()
                            .frame(maxWidth: 180)
                    }

                    LabeledField(title: "Next Due (Shared)") {
                        DatePicker("", selection: $task.nextDue, displayedComponents: [.date])
                            .labelsHidden()
                            .frame(maxWidth: 180)
                    }

                    Spacer()
                }

                HStack(spacing: 16) {
                    LabeledField(title: "Warning Days (Shared)") {
                        TextField("Warning Days", value: $task.warningDays, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                    }

                    LabeledField(title: "Critical Days (Shared)") {
                        TextField("Critical Days", value: $task.criticalDays, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                    }

                    Button("Recalculate Next Due") {
                        task.nextDue = task.frequency.nextDue(after: task.lastDone)
                    }
                    .fixedSize()
                    .help("Set Next Due to Last Done plus Frequency interval")

                    Spacer(minLength: 0)
                }

                if task.showsRunHoursTrigger(assets: assets) {
                    RunHoursTriggerEditor(
                        task: $task,
                        assets: assets,
                        onCommit: { autosaveAction(task) }
                    )
                    .padding(.top, 8)
                }

            }
        }
    }

    var responseCard: some View {
        CardView(title: "Response / How-To (Mac only)", icon: "book") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mac only — not written to the OpenClaw CSV.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $task.responseInstructions)
                    .font(.body)
                    .frame(minHeight: 230)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25))
                    )

                LabeledField(title: "Supplies Needed") {
                    TextField("Supplies Needed", text: $task.suppliesNeeded, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledField(title: "Extra Notes") {
                    TextField("Notes", text: $task.notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var partsTotalLabel: String {
        let total = task.parts.reduce(0.0) { $0 + $1.cost }
        return "Parts total: " + total.formatted(.currency(code: "USD"))
    }

    var manufacturerPartsCard: some View {
        CardView(title: "Manufacturer / Parts / Tools (Mac only)", icon: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Origin", selection: $task.origin) {
                    ForEach(TaskOrigin.allCases) { origin in
                        Text(origin.label).tag(origin)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 16) {
                    LabeledField(title: "Manufacturer") {
                        TextField("Manufacturer", text: $task.manufacturer)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField(title: "Source Manual") {
                        TextField("Manual file name", text: $task.sourceManualName)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Text("Parts (oil, filter, etc.)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text("Mac only — not published to Intel. Use Add Part for each item this job needs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if task.parts.isEmpty {
                    Text("No parts recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(task.parts.enumerated()), id: \.element.id) { index, _ in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("Part name (e.g. Engine oil)", text: $task.parts[index].name)
                                    .textFieldStyle(.roundedBorder)
                                Button(role: .destructive) {
                                    task.parts.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("OEM part number", text: $task.parts[index].oemPartNumber)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Part number", text: $task.parts[index].partNumber)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack(spacing: 8) {
                                TextField("Buy URL", text: $task.parts[index].buyURL)
                                    .textFieldStyle(.roundedBorder)
                                TextField(
                                    "Cost",
                                    value: $task.parts[index].cost,
                                    format: .currency(code: "USD")
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 120)
                            }
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Text(partsTotalLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Button {
                    task.parts.append(PartRequirement(name: "New part"))
                } label: {
                    Label("Add Part", systemImage: "plus.circle")
                }

                Text("Tools / socket sizes")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                if task.toolsRequired.isEmpty {
                    Text("No tools recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(task.toolsRequired.enumerated()), id: \.element.id) { index, tool in
                        HStack(spacing: 8) {
                            TextField("Tool", text: $task.toolsRequired[index].name)
                                .textFieldStyle(.roundedBorder)
                            TextField("Size", text: $task.toolsRequired[index].size)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 100)
                            TextField("Notes", text: $task.toolsRequired[index].notes)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                task.toolsRequired.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }

                Button {
                    task.toolsRequired.append(ToolRequirement(name: "New tool"))
                } label: {
                    Label("Add Tool", systemImage: "plus.circle")
                }
            }
        }
    }

    var responsePreviewCard: some View {

        CardView(title: "Response Preview", icon: "eye") {
            VStack(alignment: .leading, spacing: 10) {
                Text(TaskTitle.displayFullTitle(area: task.area, item: task.item, assetId: task.assetId, assets: assets))
                    .font(.headline)
                    .fontWeight(.bold)

                Text(task.taskDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                Text("How-To Response")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)

                Text(task.responseInstructions)
                    .font(.subheadline)
                    .lineSpacing(3)

                if !task.suppliesNeeded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()

                    Text("Supplies Needed")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)

                    Text(task.suppliesNeeded)
                        .font(.subheadline)
                }

                if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()

                    Text("Notes")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)

                    Text(task.notes)
                        .font(.subheadline)
                }
            }
        }
    }

    var completionCard: some View {
        CardView(title: "Completion Tracking", icon: "checkmark.circle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        completeAction()
                    } label: {
                        Label("Mark Complete", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Text("Last done: \(DateHelper.isoDate(task.lastDone))")
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                LabeledField(title: "Result Notes") {
                    TextEditor(text: $task.resultNotes)
                        .font(.body)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.25))
                        )
                }
            }
        }
    }


    var historyCard: some View {
        CardView(title: "Maintenance History", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                if task.completionHistory.isEmpty {
                    Text("No completion history yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(task.completionHistory.prefix(10), id: \.self) { entry in
                        Text(entry)
                            .font(.subheadline)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    var automationCard: some View {
        CardView(title: "Automation Options", icon: "gearshape") {
            HStack(spacing: 24) {
                Toggle("Send Telegram Update", isOn: $task.sendTelegramUpdate)
                Toggle("Include in Daily Briefing", isOn: $task.includeInDailyBriefing)
                Toggle("Alert if Overdue", isOn: $task.alertIfOverdue)
            }
        }
    }

    var bottomActionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    deleteAction()
                } label: {
                    Label("Delete Task", systemImage: "trash")
                }
                .fixedSize()

                Button {
                    duplicateAction()
                } label: {
                    Label("Duplicate Task", systemImage: "doc.on.doc")
                }
                .fixedSize()

                Spacer(minLength: 0)

                Button {
                    fillHowToAction()
                } label: {
                    Label("Fill How-To from Manual", systemImage: "doc.richtext")
                }
                .fixedSize()
                .disabled(isFillingHowTo)
            }

            HStack(spacing: 12) {
                Spacer(minLength: 0)

                Button {
                    saveAction()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .fixedSize()
                .help("Upsert this task to Postgres without completing it. Result appears in Action Result.")

                Button {
                    completeAction()
                } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .fixedSize()
                .help("Mark complete on the server (advances next due). Does not replace Save for field edits.")
            }
        }
        .padding(16)
    }

    func applyOwnerHowToTemplate() {
        task.origin = .owner
        let title = TaskTitle.displayFullTitle(area: task.area, item: task.item, assetId: task.assetId, assets: assets)
        task.responseInstructions = """
        1. Inspect \(title).

        2. Complete the required maintenance.

        3. Record readings, supplies used, or problems found.

        4. Add follow-up notes if another task is needed.

        5. Mark the task complete.
        """
    }

    func markComplete() {
        task.lastDone = Date()
        task.nextDue = Calendar.current.date(byAdding: .day, value: task.warningDays, to: task.lastDone) ?? task.lastDone

        let trimmedNotes = task.resultNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let completionDate = DateHelper.isoDate(task.lastDone)
        let historyNote: String

        if trimmedNotes.isEmpty || (trimmedNotes.hasPrefix("Completed on ") && trimmedNotes.hasSuffix(".")) {
            historyNote = "Completed on \(completionDate)."
            task.resultNotes = historyNote
        } else {
            historyNote = trimmedNotes
        }

        let entry = "\(completionDate) — \(historyNote)"

        if !task.completionHistory.contains(entry) {
            task.completionHistory.insert(entry, at: 0)
        }
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.headline)
                    .fontWeight(.bold)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.16))
        )
    }
}

struct CardView<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
            }

            content
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.18))
        )
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            content
        }
    }
}



struct URLManualImportSheet: View {
    @Binding var isPresented: Bool
    let statusMessage: String
    let onFetch: (String) -> Void

    @State private var urlText = ""
    @State private var isFetching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from URL")
                .font(.title2)
                .fontWeight(.bold)

            Text("Paste a manufacturer manual TOC or section page URL. Fetches ≤20 HTML pages (~90k chars), SHA256-checksums the corpus, asks local Ollama, then opens review with provenance. Full manuals are not archived.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://manuals.example.com/.../toc.html", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .disabled(isFetching)

            if isFetching || statusMessage.localizedCaseInsensitiveContains("Fetching manual")
                || statusMessage.localizedCaseInsensitiveContains("asking local Ollama") {
                ProgressView(statusMessage.isEmpty ? "Working…" : statusMessage)
            } else if statusMessage.localizedCaseInsensitiveContains("URL import failed")
                || statusMessage.localizedCaseInsensitiveContains("Manual URL import failed") {
                Text(statusMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isFetching)

                Button("Fetch") {
                    isFetching = true
                    onFetch(urlText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFetching || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .onChange(of: statusMessage) { newValue in
            if newValue.localizedCaseInsensitiveContains("URL import failed")
                || newValue.localizedCaseInsensitiveContains("Manual URL import failed")
                || newValue.localizedCaseInsensitiveContains("Proposed") {
                isFetching = false
            }
        }
    }
}

struct ManualImportReviewSheet: View {
    let manufacturer: String
    @Binding var drafts: [ManualImportDraft]
    let onCancel: () -> Void
    let onImport: () -> Void

    private var corpusProvenance: ManualSourceProvenance? {
        drafts.first(where: { !$0.provenance.originalURL.isEmpty })?.provenance
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manufacturer Manual Import")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(manufacturer.isEmpty ? "Review proposed maintenance tasks" : manufacturer)
                        .foregroundStyle(.secondary)
                    if let p = corpusProvenance {
                        Text("Source: \(p.originalURL)")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            if !p.retrievedAtISO.isEmpty {
                                Text("Retrieved \(p.retrievedAtISO)")
                            }
                            if !p.contentChecksumSHA256.isEmpty {
                                Text("SHA256 \(String(p.contentChecksumSHA256.prefix(12)))…")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if !p.manualTitle.isEmpty || !p.publicationNumber.isEmpty || !p.model.isEmpty {
                            Text(
                                [
                                    p.manualTitle.isEmpty ? nil : "Title: \(p.manualTitle)",
                                    p.publicationNumber.isEmpty ? nil : "Pub: \(p.publicationNumber)",
                                    p.model.isEmpty ? nil : "Model: \(p.model)",
                                    p.serialNumberApplicability.isEmpty ? nil : "Serial: \(p.serialNumberApplicability)"
                                ].compactMap { $0 }.joined(separator: " · ")
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Import Selected") {
                    onImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(drafts.allSatisfy { !$0.selected })
            }
            .padding()

            Divider()

            List {
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $draft.selected) {
                            Text("\(draft.area) — \(draft.item)")
                                .fontWeight(.semibold)
                        }
                        Text(draft.taskDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Every \(draft.frequency.rawValue) · warn \(draft.warningDays)d / critical \(draft.criticalDays)d · \(draft.estimatedMinutes) min")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Text(String(format: "Confidence %.0f%%", draft.confidence * 100))
                            Text(draft.verificationStatus.label)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        if !draft.sourceFacts.maintenanceInterval.isEmpty {
                            Text("Interval (source): \(draft.sourceFacts.maintenanceInterval)")
                                .font(.caption2)
                        }
                        if !draft.sourceFacts.fluids.isEmpty {
                            Text("Fluids: \(draft.sourceFacts.fluids.joined(separator: "; "))")
                                .font(.caption2)
                        }
                        if !draft.sourceFacts.capacities.isEmpty {
                            Text("Capacities: \(draft.sourceFacts.capacities.joined(separator: "; "))")
                                .font(.caption2)
                        }
                        if !draft.sourceFacts.filters.isEmpty {
                            Text("Filters: \(draft.sourceFacts.filters.joined(separator: "; "))")
                                .font(.caption2)
                        }
                        if !draft.sourceFacts.safetyWarnings.isEmpty {
                            Text("Safety: \(draft.sourceFacts.safetyWarnings.joined(separator: "; "))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !draft.partNumbers.isEmpty {
                            Text("Parts: \(draft.partNumbers.joined(separator: ", "))")
                                .font(.caption2)
                        }
                        if !draft.toolsRequired.isEmpty {
                            Text(
                                "Tools: "
                                    + draft.toolsRequired.map { tool in
                                        tool.size.isEmpty ? tool.name : "\(tool.name) (\(tool.size))"
                                    }.joined(separator: ", ")
                            )
                            .font(.caption2)
                        }
                        if !draft.sourceFacts.sectionSourceURLs.isEmpty {
                            Text("Section: \(draft.sourceFacts.sectionSourceURLs.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        } else if !draft.referenceURLs.isEmpty {
                            Text("URLs: \(draft.referenceURLs.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                        if !draft.sourceFacts.sourceExcerpt.isEmpty {
                            Text("Excerpt (source): \"\(draft.sourceFacts.sourceExcerpt)\"")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(5)
                        }
                        if !draft.inferredNotes.isEmpty {
                            Text("AI inference: \(draft.inferredNotes)")
                                .font(.caption)
                                .foregroundStyle(.purple)
                                .lineLimit(4)
                        }
                        Text(draft.responseInstructions)
                            .font(.caption)
                            .lineLimit(6)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct BriefingCounts {
    let tasksToday: Int
    let overdue: Int
    let dueThisWeek: Int

    init(tasks: [MaintenanceTask]) {
        var calendar = Calendar.current
        calendar.timeZone = DateHelper.centralTimeZone
        let today = calendar.startOfDay(for: Date())
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today

        var todayCount = 0
        var overdueCount = 0
        var weekCount = 0

        for task in tasks where task.isActive {
            let due = calendar.startOfDay(for: task.nextDue)
            let critical = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: task.criticalDays, to: task.lastDone) ?? task.nextDue
            )
            let isOverdue = today >= critical
            let isDueToday = calendar.isDate(due, inSameDayAs: today)

            if isOverdue {
                overdueCount += 1
            }

            // Briefing "today" = flagged tasks that are due today or already overdue.
            if task.includeInDailyBriefing && (isDueToday || isOverdue) {
                todayCount += 1
            }

            if due >= today && due < weekEnd {
                weekCount += 1
            }
        }

        self.tasksToday = todayCount
        self.overdue = overdueCount
        self.dueThisWeek = weekCount
    }
}

enum DateHelper {
    static let centralTimeZone = TimeZone(identifier: "America/Chicago")!

    static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = centralTimeZone
        return formatter.string(from: date)
    }

    static func centralLongDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = centralTimeZone
        return formatter.string(from: date)
    }

    static func centralClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = centralTimeZone
        return formatter.string(from: date)
    }
}
