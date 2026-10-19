import Foundation
import Observation
import Security

/// The PropertyManager surface intentionally has no mutation operations.
@MainActor
@Observable
final class RanchOSPropertyLiveStore {
    enum State: Equatable {
        case loading
        case ready(RanchOSPropertyLiveDashboard)
        case unavailable(String)
    }

    private(set) var environment: RanchOSRuntimeEnvironment
    private(set) var state: State = .loading

    init(environment: RanchOSRuntimeEnvironment = RanchOSLiveSession.persistedEnvironment()) {
        self.environment = environment
        // Security.framework calls can block on a prompt or daemon round-trip and must
        // never run on the main actor: a blocked main thread stops all app input.
        var launchCredentials: [RanchOSRuntimeEnvironment: String] = [:]
        for option in RanchOSRuntimeEnvironment.allCases {
            if let value = ProcessInfo.processInfo.environment[option.propertyLaunchKeyEnvironment], !value.isEmpty {
                launchCredentials[option] = value
            }
        }
        Task { [weak self] in
            for (option, credential) in launchCredentials {
                await Task.detached { Self.storeKeychainCredential(credential, for: option) }.value
            }
            await self?.refresh()
        }
    }

    func useEnvironment(_ environment: RanchOSRuntimeEnvironment) async {
        self.environment = environment
        await refresh()
    }

    func refresh() async {
        let current = environment
        let apiKey = await Task.detached { Self.keychainCredential(for: current) }.value

        state = .loading
        do {
            var request = URLRequest(url: current.propertyBaseURL.appending(path: "tasks"))
            request.httpMethod = "GET"
            request.timeoutInterval = 45
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PropertyError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw PropertyError.httpStatus(httpResponse.statusCode)
            }

            state = .ready(try RanchOSPropertyLiveDashboard.decode(from: data))
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    private nonisolated static func keychainCredential(for environment: RanchOSRuntimeEnvironment) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: environment.propertyKeychainService,
            kSecAttrAccount as String: environment.propertyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func storeKeychainCredential(
        _ credential: String,
        for environment: RanchOSRuntimeEnvironment
    ) {
        let data = Data(credential.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: environment.propertyKeychainService,
            kSecAttrAccount as String: environment.propertyKeychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        if SecItemUpdate(identity as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}

enum PropertyError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "PropertyManager returned an invalid response."
        case .httpStatus(401), .httpStatus(403): "PropertyManager did not authorize this device."
        case .httpStatus(let code): "PropertyManager is unavailable (HTTP \(code))."
        }
    }
}

struct RanchOSPropertyLiveDashboard: Equatable {
    let tasks: [RanchOSPropertyLiveTask]

    var activeTaskCount: Int { tasks.filter(\.isActive).count }
    var attentionCount: Int { tasks.filter { $0.status == .needsAttention }.count }
    var dueTasks: [RanchOSPropertyLiveTask] { tasks.filter(\.isActive) }

    var dueTaskCategoryFilters: [RanchOSPropertyDueTaskCategoryFilter] {
        let names = Set(dueTasks.map(\.categoryName)).sorted()
        return [.all] + names.map(RanchOSPropertyDueTaskCategoryFilter.category)
    }

    func dueTasks(matching filter: RanchOSPropertyDueTaskCategoryFilter) -> [RanchOSPropertyLiveTask] {
        switch filter {
        case .all:
            dueTasks
        case .category(let name):
            dueTasks.filter { $0.categoryName == name }
        }
    }

    func resolvedFilter(_ current: RanchOSPropertyDueTaskCategoryFilter) -> RanchOSPropertyDueTaskCategoryFilter {
        switch current {
        case .all:
            .all
        case .category:
            dueTaskCategoryFilters.contains(current) ? current : .all
        }
    }

    static func decode(from data: Data) throws -> RanchOSPropertyLiveDashboard {
        let object = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let dictionary = object as? [String: Any], let array = dictionary["items"] as? [[String: Any]] {
            items = array
        } else {
            throw PropertyError.invalidResponse
        }
        return RanchOSPropertyLiveDashboard(tasks: items.compactMap(RanchOSPropertyLiveTask.init(payload:)))
    }
}

struct RanchOSPropertyLiveTask: Identifiable, Equatable {
    enum Status: Equatable {
        case needsAttention
        case upcoming
        case current
    }

    let id: String
    let title: String
    let area: String
    let categoryName: String
    let nextDue: String?
    let isActive: Bool
    let priority: String?

    init?(payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let title = payload["item"] as? String,
              !id.isEmpty, !title.isEmpty else {
            return nil
        }
        self.id = id
        self.title = title
        self.area = (payload["area"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Property"
        let rawCategory = (payload["category_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.categoryName = rawCategory.isEmpty ? RanchOSPropertyLiveTask.uncategorizedName : rawCategory
        self.nextDue = payload["next_due"] as? String
        self.isActive = payload["is_active"] as? Bool ?? true
        self.priority = payload["priority"] as? String
    }

    static let uncategorizedName = "Uncategorized"

    var status: Status {
        guard isActive else { return .current }
        guard let nextDue, let date = Self.parseDate(nextDue) else { return .upcoming }
        return date < Calendar.current.startOfDay(for: .now) ? .needsAttention : .upcoming
    }

    var detail: String {
        let due = nextDue.map { "Due \($0)" } ?? "No date scheduled"
        return "\(categoryName) · \(area) · \(due)"
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

enum RanchOSPropertyDueTaskCategoryFilter: Hashable, Sendable, Identifiable {
    case all
    case category(String)

    var id: String {
        switch self {
        case .all: "all"
        case .category(let name): "category:\(name)"
        }
    }

    var label: String {
        switch self {
        case .all: "All categories"
        case .category(let name): name
        }
    }
}
