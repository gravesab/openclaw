import Foundation
import Observation
import Security

/// The PropertyManager DEV surface intentionally has no mutation operations.
@MainActor
@Observable
final class RanchOSPropertyLiveStore {
    enum State: Equatable {
        case loading
        case ready(RanchOSPropertyLiveDashboard)
        case unavailable(String)
    }

    #if os(tvOS)
    // Apple TV is not on the tailnet; the M4's LaunchAgent
    // ai.openclaw.propertymanager-dev-lan-relay forwards this port to the same DEV API.
    private static let endpoint = URL(string: "http://andrew-m4-pro.local:15063")!
    #else
    private static let endpoint = URL(string: "http://100.85.188.74:5062")!
    #endif
    private nonisolated static let keychainService = "ai.openclaw.ranchos.dev.property"
    private nonisolated static let keychainAccount = "propertymanager-dev-api-key"
    private static let launchKeyEnvironment = "RANCHOS_PROPERTYMANAGER_DEV_API_KEY"

    private(set) var state: State = .loading

    init() {
        // Security.framework calls can block on a prompt or daemon round-trip and must
        // never run on the main actor: a blocked main thread stops all app input.
        let launchCredential = ProcessInfo.processInfo.environment[Self.launchKeyEnvironment]
        Task { [weak self] in
            if let launchCredential, !launchCredential.isEmpty {
                await Task.detached { Self.storeKeychainCredential(launchCredential) }.value
            }
            await self?.refresh()
        }
    }

    func refresh() async {
        let apiKey = await Task.detached { Self.keychainCredential() }.value
        guard let apiKey, !apiKey.isEmpty else {
            state = .unavailable("The DEV Property connection is not available on this device.")
            return
        }

        state = .loading
        do {
            var request = URLRequest(url: Self.endpoint.appending(path: "tasks"))
            request.httpMethod = "GET"
            request.timeoutInterval = 45
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

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

    private nonisolated static func keychainCredential() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
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

    private nonisolated static func storeKeychainCredential(_ credential: String) {
        let data = Data(credential.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
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
        case .invalidResponse: "PropertyManager DEV returned an invalid response."
        case .httpStatus(401), .httpStatus(403): "PropertyManager DEV did not authorize this device."
        case .httpStatus(let code): "PropertyManager DEV is unavailable (HTTP \(code))."
        }
    }
}

struct RanchOSPropertyLiveDashboard: Equatable {
    let tasks: [RanchOSPropertyLiveTask]

    var activeTaskCount: Int { tasks.filter(\.isActive).count }
    var attentionCount: Int { tasks.filter { $0.status == .needsAttention }.count }

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
        self.nextDue = payload["next_due"] as? String
        self.isActive = payload["is_active"] as? Bool ?? true
        self.priority = payload["priority"] as? String
    }

    var status: Status {
        guard isActive else { return .current }
        guard let nextDue, let date = Self.parseDate(nextDue) else { return .upcoming }
        return date < Calendar.current.startOfDay(for: .now) ? .needsAttention : .upcoming
    }

    var detail: String {
        let due = nextDue.map { "Due \($0)" } ?? "No date scheduled"
        return "\(area) · \(due)"
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
