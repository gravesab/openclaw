import Foundation
import SwiftUI

enum PropertyManagerBuildEnvironment {
#if DEBUG
    static let isDevelopment = true
    // The DEV host binds its API and Dashboard to loopback; the M4 Max relays them over Tailscale.
    // New keys replace URLs saved for the old direct addresses, which no longer answer.
    static let apiBaseURLKey = "propertyManager.dev.v4.apiBaseURL"
    static let apiBaseURL = "http://100.104.100.96:15062"
    static let manualLibraryBaseURLKey = "propertyManager.dev.v2.manualLibraryBaseURL"
    static let manualLibraryBaseURL = "http://100.104.100.96:15051"
    /// Other addresses of the same servers; a saved one is replaced by the Tailscale address.
    /// The Mac's Wi-Fi name is listed so builds that saved it move back to Tailscale.
    static let apiOtherAddresses = ["http://andrew-m4-pro-2.local:5062"]
    static let manualLibraryOtherAddresses: [String] = []
    static let apiKeyKey = "propertyManager.dev.apiKey"
    static let operatorPINKey = "propertyManager.dev.operatorPIN"
    static let operatorIdentityKey = "propertyManager.dev.operatorIdentity"
    static let operatorIdentity = "ios-dev-operator"
    static let appearanceKey = "propertyManager.dev.appearance"
#else
    static let isDevelopment = false
    static let apiBaseURLKey = "propertyManager.apiBaseURL"
    static let apiBaseURL = "http://100.85.36.72:5062"
    static let manualLibraryBaseURLKey = "propertyManager.manualLibraryBaseURL"
    static let manualLibraryBaseURL = "http://100.85.36.72:5051"
    /// Other addresses of the Intel Mini. Older builds saved its Wi-Fi IP or .local name, which
    /// fail off the ranch and send credentials in cleartext; a saved one is replaced by Tailscale.
    static let apiOtherAddresses = ["http://192.168.50.104:5062", "http://intelmini.local:5062"]
    static let manualLibraryOtherAddresses = ["http://192.168.50.104:5051", "http://intelmini.local:5051"]
    static let apiKeyKey = "propertyManager.apiKey"
    static let operatorPINKey = "propertyManager.operatorPIN"
    static let operatorIdentityKey = "propertyManager.operatorIdentity"
    static let operatorIdentity = "ios-operator"
    static let appearanceKey = "propertyManager.appearance"
#endif
}

@MainActor
final class PropertyStore: ObservableObject {
    @AppStorage(PropertyManagerBuildEnvironment.apiBaseURLKey)
    var apiBaseURL: String = PropertyManagerBuildEnvironment.apiBaseURL
    @AppStorage(PropertyManagerBuildEnvironment.manualLibraryBaseURLKey)
    var manualLibraryBaseURL: String = PropertyManagerBuildEnvironment.manualLibraryBaseURL
    @AppStorage(PropertyManagerBuildEnvironment.apiKeyKey)
    var apiKey: String = ""
    @AppStorage(PropertyManagerBuildEnvironment.operatorPINKey)
    var operatorPIN: String = ""
    @AppStorage(PropertyManagerBuildEnvironment.operatorIdentityKey)
    var operatorIdentity: String = PropertyManagerBuildEnvironment.operatorIdentity

    @Published var categories: [MaintenanceCategory] = []
    @Published var tasks: [MaintenanceTask] = []
    @Published var assets: [RanchAsset] = []
    @Published var selectedTaskAssetId: UUID?
    @Published var deepLinkAssetId: UUID?
    @Published var filter: TaskFilter = .toDo
    @Published var originFilter: OriginFilter = .all
    @Published var selectedCategory: String = "All"
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var isLoadingAssets = false
    @Published var isCompleting = false
    @Published var isSaving = false
    @Published var isBypassing = false
    /// Rescheduled tasks inside the two-week window stay listed until refresh so the new date is visible.
    @Published private(set) var recentlyBypassedTaskIDs: Set<UUID> = []
    /// Done and Bypass leave the list immediately, even if the next due date is still inside the window.
    @Published private(set) var recentlyClearedTaskIDs: Set<UUID> = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    /// The API address requests use: the Tailscale address for any address of the built-in
    /// server, otherwise the address as typed. Credentials only go to the server over Tailscale.
    var activeAPIBaseURL: String {
        Self.baseURL(
            stored: apiBaseURL,
            builtIn: PropertyManagerBuildEnvironment.apiBaseURL,
            otherAddresses: PropertyManagerBuildEnvironment.apiOtherAddresses
        )
    }

    /// The Dashboard address library requests use, mapped the same way: these requests carry
    /// the API key and PIN too, so a saved Wi-Fi or .local alias must not be used as stored.
    var activeManualLibraryBaseURL: String {
        Self.baseURL(
            stored: manualLibraryBaseURL,
            builtIn: PropertyManagerBuildEnvironment.manualLibraryBaseURL,
            otherAddresses: PropertyManagerBuildEnvironment.manualLibraryOtherAddresses
        )
    }

    var client: PropertyAPIClient {
        PropertyAPIClient(
            baseURLString: activeAPIBaseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            operatorPIN: operatorPIN.isEmpty ? nil : operatorPIN,
            operatorIdentity: operatorIdentity.isEmpty ? nil : operatorIdentity
        )
    }

    var categoryNames: [String] {
        ["All"] + categories.map(\.name).sorted()
    }

    var selectedTaskAsset: RanchAsset? {
        guard let selectedTaskAssetId else { return nil }
        return assets.first { $0.id == selectedTaskAssetId }
    }

    var filteredTasks: [MaintenanceTask] {
        let searchWords = TaskSearch.words(in: searchText)
        return tasks
            .filter { task in
                if !TaskAssetContext.includes(
                    taskAssetId: task.assetId,
                    selectedAssetId: selectedTaskAssetId
                ) {
                    return false
                }
                if selectedCategory != "All", task.categoryName != selectedCategory {
                    return false
                }
                if let wanted = originFilter.matches, task.origin != wanted {
                    return false
                }
                if recentlyClearedTaskIDs.contains(task.id) {
                    return false
                }
                if recentlyBypassedTaskIDs.contains(task.id) {
                    return searchWords.isEmpty
                        || TaskSearch.matches(fields: searchFields(for: task), words: searchWords)
                }
                if !task.isInSchedulingWindow() { return false }
                switch filter {
                case .toDo:
                    if !task.isToDo() { return false }
                case .all:
                    break
                case .due:
                    switch task.dueStatus {
                    case .dueSoon, .overdue, .critical:
                        break
                    case .ok:
                        return false
                    }
                case .overdue:
                    switch task.dueStatus {
                    case .overdue, .critical:
                        break
                    default:
                        return false
                    }
                }
                if !searchWords.isEmpty, !TaskSearch.matches(fields: searchFields(for: task), words: searchWords) {
                    return false
                }
                return true
            }
    }

    func searchFields(for task: MaintenanceTask) -> [String] {
        let group = TaskTitle.displayAssetName(task: task, assets: assets)
        return [
            task.area,
            task.item,
            group,
            TaskTitle.displayItemTitle(item: task.item, group: group),
            task.categoryName,
            task.priority,
            task.notes ?? "",
            task.taskDescription ?? "",
            task.partNumber ?? "",
            task.vendor ?? "",
            task.suppliesNeeded ?? "",
            task.primaryPartNumber ?? "",
            task.origin.label,
            task.manufacturer ?? "",
            task.sourceManualName ?? "",
        ]
    }

    func assetMatches(for query: String) -> [AssetSearchMatch] {
        TaskSearch.assetMatches(
            assets: assets,
            tasks: tasks,
            words: TaskSearch.words(in: query),
            taskFields: searchFields(for:),
            taskTitle: { task in
                TaskTitle.displayItemTitle(item: task.item, group: TaskTitle.displayAssetName(task: task, assets: self.assets))
            }
        )
    }

    /// Sections by asset name (or area), A–Z; within section display title A–Z.
    var groupedTasks: [TaskGroupSection] {
        let filtered = filteredTasks
        var buckets: [String: [MaintenanceTask]] = [:]
        for task in filtered {
            let key = TaskTitle.displayAssetName(task: task, assets: assets)
            buckets[key, default: []].append(task)
        }
        return buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                let sortedTasks = (buckets[name] ?? []).sorted { lhs, rhs in
                    let l = TaskTitle.displayItemTitle(item: lhs.item, group: name)
                    let r = TaskTitle.displayItemTitle(item: rhs.item, group: name)
                    return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                }
                return TaskGroupSection(name: name, tasks: sortedTasks)
            }
    }

    var overdueCount: Int {
        tasks.filter {
            switch $0.dueStatus {
            case .overdue, .critical: return true
            default: return false
            }
        }.count
    }

    var dueSoonCount: Int {
        tasks.filter {
            if case .dueSoon = $0.dueStatus { return true }
            return false
        }.count
    }

    func activeTaskCount(inCategoryNamed name: String) -> Int {
        tasks.filter { $0.categoryName.caseInsensitiveCompare(name) == .orderedSame && $0.isActive }.count
    }

    func destinationCategories(excluding name: String) -> [MaintenanceCategory] {
        categories
            .filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True when a saved address is one of the built-in server's own addresses.
    static func isBuiltInServer(stored: String, builtIn: String, otherAddresses: [String] = []) -> Bool {
        let typed = trimmedAddress(stored)
        return typed == builtIn || otherAddresses.contains(typed)
    }

    /// The built-in server always means its Tailscale address; any other address is used as typed.
    static func baseURL(stored: String, builtIn: String, otherAddresses: [String] = []) -> String {
        isBuiltInServer(stored: stored, builtIn: builtIn, otherAddresses: otherAddresses) ? builtIn : trimmedAddress(stored)
    }

    private static func trimmedAddress(_ stored: String) -> String {
        stored.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Shows the built-in address in Settings when a saved address is another address of the same server.
    private func showBuiltInAddressesInSettings() {
        typealias Env = PropertyManagerBuildEnvironment
        if apiBaseURL != Env.apiBaseURL,
           Self.isBuiltInServer(stored: apiBaseURL, builtIn: Env.apiBaseURL, otherAddresses: Env.apiOtherAddresses) {
            apiBaseURL = Env.apiBaseURL
        }
        if manualLibraryBaseURL != Env.manualLibraryBaseURL,
           Self.isBuiltInServer(stored: manualLibraryBaseURL, builtIn: Env.manualLibraryBaseURL, otherAddresses: Env.manualLibraryOtherAddresses) {
            manualLibraryBaseURL = Env.manualLibraryBaseURL
        }
    }

    func testConnection() async {
        errorMessage = nil
        statusMessage = "Testing connection…"
        showBuiltInAddressesInSettings()
        do {
            try await client.authCheck()
            let health = try await client.health()
            // Refresh without wiping the connection probe message until the end.
            await refresh(clearStatus: false)
            if errorMessage != nil {
                statusMessage = nil
                return
            }
            await refreshAssets(clearStatus: false)
            if errorMessage != nil {
                statusMessage = nil
                return
            }
            let label = health.status ?? "ok"
            statusMessage = "Online — \(label) · \(tasks.count) tasks, \(assets.count) assets"
        } catch {
            guard !error.isCancellation else { return }
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func refresh(clearStatus: Bool = true) async {
        isLoading = true
        errorMessage = nil
        if clearStatus {
            statusMessage = nil
        }
        defer { isLoading = false }

        showBuiltInAddressesInSettings()
        do {
            try await loadTasksAndCategories()
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadTasksAndCategories() async throws {
        async let fetchedCategories = client.fetchCategories()
        async let fetchedTasks = client.fetchTasks()
        categories = try await fetchedCategories
        tasks = try await fetchedTasks
        statusMessage = "Updated \(tasks.count) tasks"
    }

    func refreshAssets(clearStatus: Bool = true) async {
        isLoadingAssets = true
        if clearStatus {
            errorMessage = nil
        }
        defer { isLoadingAssets = false }
        showBuiltInAddressesInSettings()
        do {
            assets = try await client.fetchAssets()
            if statusMessage == nil
                || statusMessage?.hasPrefix("Updated") == true
                || statusMessage?.hasPrefix("Testing") == true
            {
                statusMessage = "Updated \(tasks.count) tasks, \(assets.count) assets"
            }
        } catch {
            guard !error.isCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "propertymanager" else { return }
        if url.host == "asset" {
            let token = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            Task {
                do {
                    let asset = try await client.fetchAssetByQR(token: token)
                    deepLinkAssetId = asset.id
                } catch {
                    guard !error.isCancellation else { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func complete(
        task: MaintenanceTask,
        note: String?,
        meterValue: Double? = nil,
        confirmCurrentMeter: Bool = false
    ) async -> Bool {
        isCompleting = true
        errorMessage = nil
        defer { isCompleting = false }

        do {
            let updated = try await client.completeTask(
                id: task.id,
                note: note,
                meterValueAtCompletion: meterValue,
                confirmCurrentMeter: confirmCurrentMeter
            )
            showCleared(updated)
            statusMessage = "Marked \(updated.area) / \(updated.item) done"
            await refreshAssets()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func skip(task: MaintenanceTask, note: String) async -> Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return await bypass(task: task, keepListed: false) {
            try await $0.skipTask(id: task.id, note: trimmed.isEmpty ? nil : trimmed)
        } status: { updated in
            "Skipped \(updated.item) — next due \(updated.nextDue.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    func reschedule(task: MaintenanceTask, body: [String: Any]) async -> Bool {
        // Stay listed only when the new date is still inside the two-week window.
        await bypass(task: task, keepListed: nil) {
            try await $0.rescheduleTask(id: task.id, body: body)
        } status: { updated in
            if updated.deferred == true, let held = TaskBypassPolicy.civilDate(updated.deferredUntil) {
                return "Rescheduled \(updated.item) — held until \(held.formatted(date: .abbreviated, time: .omitted))"
            }
            if body["next_due_meter_value"] != nil, let trigger = updated.nextDueMeterValue {
                return "Rescheduled \(updated.item) — due at \(NSDecimalNumber(decimal: trigger).stringValue) hrs"
            }
            return "Rescheduled \(updated.item) to \(updated.nextDue.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    private func bypass(
        task: MaintenanceTask,
        keepListed: Bool?,
        request: (PropertyAPIClient) async throws -> MaintenanceTask,
        status: (MaintenanceTask) -> String
    ) async -> Bool {
        isBypassing = true
        errorMessage = nil
        defer { isBypassing = false }
        do {
            let updated = try await request(client)
            let listed = keepListed ?? updated.isInSchedulingWindow()
            showBypassed(updated, keepListed: listed)
            statusMessage = status(updated)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Done or Bypass: leave the list right away.
    func showCleared(_ updated: MaintenanceTask) {
        if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[index] = updated
        }
        recentlyBypassedTaskIDs.remove(updated.id)
        recentlyClearedTaskIDs.insert(updated.id)
    }

    /// Reschedule inside the window keeps the row; outside the window clears it.
    func showBypassed(_ updated: MaintenanceTask, keepListed: Bool) {
        if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[index] = updated
        }
        if keepListed {
            recentlyClearedTaskIDs.remove(updated.id)
            recentlyBypassedTaskIDs.insert(updated.id)
        } else {
            recentlyBypassedTaskIDs.remove(updated.id)
            recentlyClearedTaskIDs.insert(updated.id)
        }
    }

    func clearRecentlyBypassed() {
        recentlyBypassedTaskIDs.removeAll()
        recentlyClearedTaskIDs.removeAll()
    }

    func saveEdits(taskID: UUID, fields: [String: Any], parts: [[String: Any]]? = nil) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            var updated = try await client.updateTask(id: taskID, fields: fields)
            if let parts {
                updated = try await client.replaceParts(taskID: taskID, parts: parts)
            }
            if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
                tasks[index] = updated
            }
            statusMessage = "Saved \(updated.area) / \(updated.item)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(task: MaintenanceTask) async -> Bool {
        do {
            _ = try await client.deleteTask(id: task.id)
            tasks.removeAll { $0.id == task.id }
            statusMessage = "Deleted \(task.area) / \(task.item)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func uploadWorkRequestPhotos(
        _ photos: [Data],
        existingAttachmentIDs: [String],
        idempotencyKey: String
    ) async throws -> [String] {
        var attachmentIDs = existingAttachmentIDs
        let firstUploadIndex = attachmentIDs.count
        for (index, photo) in photos.dropFirst(attachmentIDs.count).enumerated() {
            attachmentIDs.append(
                try await client.uploadWorkRequestPhoto(
                    photo,
                    idempotencyKey: "\(idempotencyKey)-photo-\(firstUploadIndex + index)"
                )
            )
        }
        return attachmentIDs
    }

    func submitWorkRequest(
        _ payload: WorkRequestSubmission,
        idempotencyKey: String
    ) async throws -> SubmittedWorkRequest {
        let result = try await client.submitWorkRequest(payload, idempotencyKey: idempotencyKey)
        statusMessage = "Submitted work request \(result.requestNumber)"
        return result
    }

    /// Soft-deactivate: hides from lists; meter history remains on the server.
    func deactivateAsset(id: UUID) async -> Bool {
        do {
            try await client.deactivateAsset(id: id)
            assets.removeAll { $0.id == id }
            statusMessage = "Deactivated asset"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteCategory(_ category: MaintenanceCategory, reassignTo: String? = nil) async -> Bool {
        do {
            _ = try await client.deleteCategory(id: category.id, reassignTo: reassignTo)
            categories.removeAll { $0.id == category.id }
            if let reassignTo {
                for index in tasks.indices where tasks[index].categoryName.caseInsensitiveCompare(category.name) == .orderedSame {
                    tasks[index].categoryName = reassignTo
                }
            } else {
                tasks.removeAll { $0.categoryName.caseInsensitiveCompare(category.name) == .orderedSame }
            }
            statusMessage = "Deleted category \(category.name)"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
