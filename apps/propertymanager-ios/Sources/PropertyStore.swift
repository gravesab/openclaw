import Foundation
import SwiftUI

@MainActor
final class PropertyStore: ObservableObject {
    @AppStorage("propertyManager.apiBaseURL") var apiBaseURL: String = "http://192.168.50.117:15062"
    @Published var apiKey: String {
        didSet { SecureCredentialStore.write(apiKey, account: "api-key") }
    }
    @Published var operatorPIN: String {
        didSet { SecureCredentialStore.write(operatorPIN, account: "operator-pin") }
    }
    @AppStorage("propertyManager.operatorIdentity") var operatorIdentity: String = "ios-operator"

    @Published var categories: [MaintenanceCategory] = []
    @Published var tasks: [MaintenanceTask] = []
    @Published var assets: [RanchAsset] = []
    @Published var deepLinkAssetId: UUID?
    @Published var filter: TaskFilter = .all
    @Published var originFilter: OriginFilter = .all
    @Published var selectedCategory: String = "All"
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var isLoadingAssets = false
    @Published var isCompleting = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    init() {
        SecureCredentialStore.migrateFromUserDefaults(
            key: "propertyManager.apiKey",
            account: "api-key"
        )
        SecureCredentialStore.migrateFromUserDefaults(
            key: "propertyManager.operatorPIN",
            account: "operator-pin"
        )
        apiKey = SecureCredentialStore.read("api-key")
        operatorPIN = SecureCredentialStore.read("operator-pin")
    }

    var client: PropertyAPIClient {
        PropertyAPIClient(
            baseURLString: apiBaseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            operatorPIN: operatorPIN.isEmpty ? nil : operatorPIN,
            operatorIdentity: operatorIdentity.isEmpty ? nil : operatorIdentity
        )
    }

    var categoryNames: [String] {
        ["All"] + categories.map(\.name).sorted()
    }

    var filteredTasks: [MaintenanceTask] {
        tasks
            .filter { task in
                if selectedCategory != "All", task.categoryName != selectedCategory {
                    return false
                }
                if let wanted = originFilter.matches, task.origin != wanted {
                    return false
                }
                switch filter {
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
                if !searchText.isEmpty {
                    let needle = searchText.lowercased()
                    let group = TaskTitle.displayAssetName(task: task, assets: assets)
                    let display = TaskTitle.displayItemTitle(item: task.item, group: group)
                    let haystack = [
                        task.area,
                        task.item,
                        group,
                        display,
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
                    ].joined(separator: " ").lowercased()
                    if !haystack.contains(needle) {
                        return false
                    }
                }
                return true
            }
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

    func testConnection() async {
        errorMessage = nil
        statusMessage = "Testing connection…"
        do {
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

        do {
            async let fetchedCategories = client.fetchCategories()
            async let fetchedTasks = client.fetchTasks()
            categories = try await fetchedCategories
            tasks = try await fetchedTasks
            statusMessage = "Updated \(tasks.count) tasks"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshAssets(clearStatus: Bool = true) async {
        isLoadingAssets = true
        if clearStatus {
            errorMessage = nil
        }
        defer { isLoadingAssets = false }
        do {
            assets = try await client.fetchAssets()
            if statusMessage == nil
                || statusMessage?.hasPrefix("Updated") == true
                || statusMessage?.hasPrefix("Testing") == true
            {
                statusMessage = "Updated \(tasks.count) tasks, \(assets.count) assets"
            }
        } catch {
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
            if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
                tasks[index] = updated
            }
            statusMessage = "Marked \(updated.area) / \(updated.item) done"
            await refreshAssets()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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

    func uploadPhoto(taskID: UUID, data: Data) async -> Bool {
        errorMessage = nil
        statusMessage = "Uploading photo to DEV PostgreSQL…"
        do {
            let fileName = try await client.uploadPhoto(taskID: taskID, data: data)
            if let index = tasks.firstIndex(where: { $0.id == taskID }),
               !tasks[index].photoFileNames.contains(fileName) {
                tasks[index].photoFileNames.append(fileName)
            }
            statusMessage = "Photo saved in DEV PostgreSQL"
            return true
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            return false
        }
    }

    func deletePhoto(taskID: UUID, fileName: String) async -> Bool {
        errorMessage = nil
        do {
            try await client.deletePhoto(taskID: taskID, fileName: fileName)
            if let index = tasks.firstIndex(where: { $0.id == taskID }) {
                tasks[index].photoFileNames.removeAll { $0 == fileName }
            }
            statusMessage = "Photo removed from DEV PostgreSQL"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
