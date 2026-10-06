import Foundation
import Observation
import Security

enum RanchOSLaunchMode: Equatable {
    static let offlineVerificationArgument = "--ranchos-offline-verification"

    case standard
    case offlineVerification

    static func resolve(arguments: [String] = CommandLine.arguments) -> RanchOSLaunchMode {
        arguments.contains(offlineVerificationArgument) ? .offlineVerification : .standard
    }
}

struct RanchOSPropertyCredentialAccess: Sendable {
    var readEnvironment: @Sendable () -> String?
    var readKeychain: @Sendable () -> String?
    var writeKeychain: @Sendable (String) -> Void

    static let system = RanchOSPropertyCredentialAccess(
        readEnvironment: {
            ProcessInfo.processInfo.environment[RanchOSPropertyLiveStore.launchKeyEnvironment]
        },
        readKeychain: ranchOSReadPropertyKeychain,
        writeKeychain: ranchOSWritePropertyKeychain)
}

struct RanchOSPropertyTransport: Sendable {
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let system = RanchOSPropertyTransport { request in
        try await URLSession.shared.data(for: request)
    }
}

/// The PropertyManager DEV surface intentionally has no mutation operations.
@MainActor
@Observable
final class RanchOSPropertyLiveStore {
    enum State: Equatable {
        case loading
        case ready(RanchOSPropertyLiveDashboard)
        case unavailable(String)
    }

    enum AssetsState: Equatable {
        case idle
        case loading
        case ready([RanchOSPropertyLiveAsset])
        case unavailable(String)
    }
    private(set) var assetsState: AssetsState = .idle

    static let offlineUnavailableMessage = "Unavailable during offline verification."
    nonisolated static let launchKeyEnvironment = "RANCHOS_PROPERTYMANAGER_DEV_API_KEY"

    #if os(tvOS)
    // Apple TV is not on the tailnet; the M4's LaunchAgent
    // ai.openclaw.propertymanager-dev-lan-relay forwards this port to the same DEV API.
    nonisolated private static let endpoint = URL(string: "http://andrew-m4-pro.local:15063")!
    #else
    nonisolated private static let endpoint = URL(string: "http://100.85.188.74:5062")!
    #endif

    private let mode: RanchOSLaunchMode
    private let credentials: RanchOSPropertyCredentialAccess
    private let transport: RanchOSPropertyTransport
    private(set) var state: State = .loading

    convenience init(mode: RanchOSLaunchMode = .standard, startsAutomaticRefresh: Bool = true) {
        self.init(
            mode: mode,
            credentials: .system,
            transport: .system,
            startsAutomaticRefresh: startsAutomaticRefresh)
    }

    init(
        mode: RanchOSLaunchMode,
        credentials: RanchOSPropertyCredentialAccess,
        transport: RanchOSPropertyTransport,
        startsAutomaticRefresh: Bool
    ) {
        self.mode = mode
        self.credentials = credentials
        self.transport = transport
        if mode == .offlineVerification {
            state = .unavailable(Self.offlineUnavailableMessage)
            assetsState = .unavailable(Self.offlineUnavailableMessage)
            return
        }
        importLaunchCredentialIfPresent()
        guard startsAutomaticRefresh else { return }
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        guard mode != .offlineVerification else {
            state = .unavailable(Self.offlineUnavailableMessage)
            return
        }
        guard let apiKey = credentials.readKeychain(), !apiKey.isEmpty else {
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

            let (data, response) = try await transport.send(request)
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

    func refreshAssets() async {
        guard mode != .offlineVerification else {
            assetsState = .unavailable(Self.offlineUnavailableMessage)
            return
        }
        guard assetsState != .loading, !Task.isCancelled else { return }
        guard let apiKey = credentials.readKeychain(), !apiKey.isEmpty else {
            assetsState = .unavailable("The DEV Property connection is not available on this device.")
            return
        }
        let previous = assetsState
        assetsState = .loading
        do {
            var request = URLRequest(url: Self.endpoint.appending(path: "v1/assets"))
            request.httpMethod = "GET"
            request.timeoutInterval = 45
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw PropertyError.invalidResponse }
            guard http.statusCode == 200 else { throw PropertyError.httpStatus(http.statusCode) }
            assetsState = .ready(try RanchOSPropertyLiveAsset.decode(from: data))
        } catch {
            assetsState = Task.isCancelled ? previous : .unavailable(error.localizedDescription)
        }
    }

    private func importLaunchCredentialIfPresent() {
        guard let credential = credentials.readEnvironment(), !credential.isEmpty else {
            return
        }
        credentials.writeKeychain(credential)
    }
}

private let ranchOSPropertyKeychainService = "ai.openclaw.ranchos.dev.property"
private let ranchOSPropertyKeychainAccount = "propertymanager-dev-api-key"

private func ranchOSReadPropertyKeychain() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: ranchOSPropertyKeychainService,
        kSecAttrAccount as String: ranchOSPropertyKeychainAccount,
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

private func ranchOSWritePropertyKeychain(_ credential: String) {
    let data = Data(credential.utf8)
    let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: ranchOSPropertyKeychainService,
        kSecAttrAccount as String: ranchOSPropertyKeychainAccount,
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
    let assetID: UUID?
    let taskDescription: String?
    let instructions: String?
    let supplies: String?
    let notes: String?
    let frequency: String?
    let lastDone: String?
    let sourceManual: String?
    let parts: [RanchOSPropertyLivePart]?
    let legacyPart: RanchOSPropertyLivePart?

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
        self.assetID = (payload["asset_id"] as? String).flatMap(UUID.init(uuidString:))
        self.taskDescription = payload["task_description"] as? String
        self.instructions = payload["response_instructions"] as? String
        self.supplies = payload["supplies_needed"] as? String
        self.notes = payload["notes"] as? String
        self.frequency = payload["frequency"] as? String
        self.lastDone = payload["last_done"] as? String
        self.sourceManual = payload["source_manual_name"] as? String
        self.parts = (payload["parts"] as? [[String: Any]])?.map(RanchOSPropertyLivePart.init)
        let legacy = RanchOSPropertyLivePart(payload: [
            "part_number": payload["part_number"] ?? NSNull(), "buy_url": payload["part_url"] ?? NSNull(),
            "vendor": payload["vendor"] ?? NSNull(), "cost": payload["part_cost"] ?? NSNull()
        ])
        self.legacyPart = legacy.hasDetails ? legacy : nil
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

struct RanchOSPropertyLiveAsset: Identifiable, Equatable, Decodable {
    let id: UUID
    let name: String
    let category: String?
    let location: String?
    let manufacturer: String?
    let model: String?

    static func decode(from data: Data) throws -> [Self] {
        struct Envelope: Decodable { let items: [RanchOSPropertyLiveAsset] }
        let decoder = JSONDecoder()
        let assets: [Self]
        if let array = try? decoder.decode([Self].self, from: data) { assets = array }
        else { assets = try decoder.decode(Envelope.self, from: data).items }
        guard Set(assets.map(\.id)).count == assets.count,
              assets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PropertyError.invalidResponse
        }
        return assets.sorted { ($0.name.localizedLowercase, $0.id.uuidString) < ($1.name.localizedLowercase, $1.id.uuidString) }
    }
}

struct RanchOSPropertyLivePart: Equatable {
    let name: String?
    let number: String?
    let oemNumber: String?
    let vendor: String?
    let quantity: String?
    let cost: String?
    let buyURL: String?
    let notes: String?

    init(payload: [String: Any]) {
        func text(_ key: String) -> String? {
            let value = (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        func numberText(_ key: String) -> String? {
            if let value = text(key) { return value }
            return (payload[key] as? NSNumber)?.stringValue
        }
        name = text("name")
        number = text("part_number")
        oemNumber = text("oem_part_number")
        vendor = text("vendor")
        quantity = numberText("quantity")
        cost = numberText("cost")
        buyURL = text("buy_url")
        notes = text("notes")
    }
    var hasDetails: Bool { [name, number, oemNumber, vendor, quantity, cost, buyURL, notes].contains { $0 != nil } }
}
