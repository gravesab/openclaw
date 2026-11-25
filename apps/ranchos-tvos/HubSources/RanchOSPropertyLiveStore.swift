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

    static let system = system(for: .development)

    /// DEV and Production never share a launch key or a Keychain item.
    static func system(for environment: RanchOSRuntimeEnvironment) -> RanchOSPropertyCredentialAccess {
        let launchKey = environment.propertyLaunchKeyEnvironment
        let service = environment.propertyKeychainService
        let account = environment.propertyKeychainAccount
        return RanchOSPropertyCredentialAccess(
            readEnvironment: { ProcessInfo.processInfo.environment[launchKey] },
            readKeychain: { ranchOSReadPropertyKeychain(service: service, account: account) },
            writeKeychain: { ranchOSWritePropertyKeychain($0, service: service, account: account) })
    }
}

struct RanchOSPropertyTransport: Sendable {
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let system = RanchOSPropertyTransport { request in
        try await URLSession.shared.data(for: request)
    }
}

/// The PropertyManager surface intentionally has no mutation operations.
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

    private let mode: RanchOSLaunchMode
    private let credentialsFor: (RanchOSRuntimeEnvironment) -> RanchOSPropertyCredentialAccess
    private var credentials: RanchOSPropertyCredentialAccess
    private let transport: RanchOSPropertyTransport
    private var launchImport: Task<Void, Never>?
    private(set) var environment: RanchOSRuntimeEnvironment
    private(set) var state: State = .loading

    convenience init(
        mode: RanchOSLaunchMode = .standard,
        environment: RanchOSRuntimeEnvironment = RanchOSLiveSession.persistedEnvironment(),
        startsAutomaticRefresh: Bool = true
    ) {
        self.init(
            mode: mode,
            environment: environment,
            credentialsFor: { .system(for: $0) },
            transport: .system,
            startsAutomaticRefresh: startsAutomaticRefresh)
    }

    /// Injected credentials serve every environment (tests and previews).
    convenience init(
        mode: RanchOSLaunchMode,
        environment: RanchOSRuntimeEnvironment = .development,
        credentials: RanchOSPropertyCredentialAccess,
        transport: RanchOSPropertyTransport,
        startsAutomaticRefresh: Bool
    ) {
        self.init(
            mode: mode,
            environment: environment,
            credentialsFor: { _ in credentials },
            transport: transport,
            startsAutomaticRefresh: startsAutomaticRefresh)
    }

    private init(
        mode: RanchOSLaunchMode,
        environment: RanchOSRuntimeEnvironment,
        credentialsFor: @escaping (RanchOSRuntimeEnvironment) -> RanchOSPropertyCredentialAccess,
        transport: RanchOSPropertyTransport,
        startsAutomaticRefresh: Bool
    ) {
        self.mode = mode
        self.environment = environment
        self.credentialsFor = credentialsFor
        self.credentials = credentialsFor(environment)
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

    /// Switches DEV/Production. Each environment keeps its own key and endpoint.
    func useEnvironment(_ environment: RanchOSRuntimeEnvironment) async {
        guard mode != .offlineVerification else { return }
        self.environment = environment
        credentials = credentialsFor(environment)
        assetsState = .idle
        importLaunchCredentialIfPresent()
        await refresh()
    }

    /// Finishes any launch-key import before the first read uses the Keychain.
    func finishLaunchImport() async {
        await launchImport?.value
    }

    private var unavailableConnectionMessage: String {
        "The \(environment.title) Property connection is not available on this device."
    }

    private func failureMessage(_ error: Error) -> String {
        (error as? PropertyError)?.message(for: environment) ?? error.localizedDescription
    }

    // Security.framework calls can block on a prompt or daemon round-trip and must
    // never run on the main actor: a blocked main thread stops all app input.
    private func readCredential() async -> String? {
        await finishLaunchImport()
        let access = credentials
        return await Task.detached { access.readKeychain() }.value
    }

    func refresh() async {
        guard mode != .offlineVerification else {
            state = .unavailable(Self.offlineUnavailableMessage)
            return
        }
        let endpoint = environment.propertyBaseURL
        guard let apiKey = await readCredential(), !apiKey.isEmpty else {
            state = .unavailable(unavailableConnectionMessage)
            return
        }

        state = .loading
        do {
            var request = URLRequest(url: endpoint.appending(path: "tasks"))
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
            state = .unavailable(failureMessage(error))
        }
    }

    /// Reloads the asset summary while this screen is open, so a DEV change replaces the list.
    func trackAssets() async {
        // Keep an already-ready summary on screen when Property reopens (no loading flash).
        var keepVisibleSummary: Bool = {
            if case .ready = assetsState { return true }
            return false
        }()
        while !Task.isCancelled {
            await refreshAssets(keepsVisibleSummary: keepVisibleSummary)
            keepVisibleSummary = true
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
        }
    }

    func refreshAssets(keepsVisibleSummary: Bool = false) async {
        guard mode != .offlineVerification else {
            assetsState = .unavailable(Self.offlineUnavailableMessage)
            return
        }
        guard assetsState != .loading, !Task.isCancelled else { return }
        let endpoint = environment.propertyBaseURL
        guard let apiKey = await readCredential(), !apiKey.isEmpty else {
            assetsState = .unavailable(unavailableConnectionMessage)
            return
        }
        let previous = assetsState
        let showingSummary = keepsVisibleSummary && {
            if case .ready = previous { return true }
            return false
        }()
        if !showingSummary {
            assetsState = .loading
        }
        do {
            var request = URLRequest(url: endpoint.appending(path: "v1/assets"))
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
            if Task.isCancelled || showingSummary {
                if case .loading = assetsState { assetsState = previous }
                return
            }
            assetsState = .unavailable(failureMessage(error))
        }
    }

    /// Reads the launch key now; the Keychain write runs off the main actor.
    private func importLaunchCredentialIfPresent() {
        guard let credential = credentials.readEnvironment(), !credential.isEmpty else {
            return
        }
        let access = credentials
        let previous = launchImport
        launchImport = Task.detached {
            await previous?.value
            access.writeKeychain(credential)
        }
    }
}

private func ranchOSReadPropertyKeychain(service: String, account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
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

private func ranchOSWritePropertyKeychain(_ credential: String, service: String, account: String) {
    let data = Data(credential.utf8)
    let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
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

    func message(for environment: RanchOSRuntimeEnvironment) -> String {
        let name = "PropertyManager \(environment.title)"
        switch self {
        case .invalidResponse: return "\(name) returned an invalid response."
        case .httpStatus(401), .httpStatus(403): return "\(name) did not authorize this device."
        case .httpStatus(let code): return "\(name) is unavailable (HTTP \(code))."
        }
    }

    var errorDescription: String? { message(for: .development) }
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
    let estimatedMinutes: Int?
    let scheduleKind: String?
    let kind: String?

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
        self.categoryName = rawCategory.isEmpty ? Self.uncategorizedName : rawCategory
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
        self.estimatedMinutes = Self.wholeMinutes(payload["estimated_minutes"])
        self.scheduleKind = payload["schedule_kind"] as? String
        self.kind = payload["kind"] as? String
    }

    static let uncategorizedName = "Uncategorized"

    var isWorkRequest: Bool {
        let normalized = (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "work request" || normalized == "work_request"
    }

    var nextDueDate: Date? {
        guard let nextDue else { return nil }
        return Self.parseDate(nextDue)
    }

    private static func wholeMinutes(_ value: Any?) -> Int? {
        let number: NSNumber?
        if let value = value as? Int {
            number = NSNumber(value: value)
        } else {
            number = value as? NSNumber
        }
        guard let number else { return nil }
        let minutes = number.doubleValue
        guard minutes >= 0, minutes.rounded(.towardZero) == minutes, minutes <= Double(Int.max) else {
            return nil
        }
        return number.intValue
    }

    var status: Status {
        guard isActive else { return .current }
        guard let date = nextDueDate else { return .upcoming }
        return date < Calendar.current.startOfDay(for: .now) ? .needsAttention : .upcoming
    }

    var detail: String {
        let due = nextDue.map { "Due \($0)" } ?? "No date scheduled"
        return "\(categoryName) · \(area) · \(due)"
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: value) { return date }

        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone.current
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: value)
    }
}

struct RanchOSPropertyAssetLink: Identifiable, Equatable, Sendable, Decodable {
    let id: UUID
    let name: String
}

struct RanchOSPropertyRelationshipMember: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let detail: String
}

/// One high-level row: a group or host with the assets related to it, or a single asset.
struct RanchOSPropertyRelationshipSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let detail: String
    let members: [RanchOSPropertyRelationshipMember]
}

struct RanchOSPropertyLiveAsset: Identifiable, Equatable, Decodable {
    let id: UUID
    let name: String
    let category: String?
    let location: String?
    let manufacturer: String?
    let model: String?
    /// Property Manager pseudo groups never own tasks; always treated as zero.
    let isPseudo: Bool
    /// Live count from Property Manager `pm_summary.active_task_count`.
    let activeTaskCount: Int
    let hostAssetID: UUID?
    let hostName: String?
    /// Related assets whose host is this asset, as returned by Property Manager.
    let attachments: [RanchOSPropertyAssetLink]

    var activeTasksLabel: String {
        activeTaskCount == 1 ? "1 active task" : "\(activeTaskCount) active tasks"
    }

    init(
        id: UUID,
        name: String,
        category: String?,
        location: String?,
        manufacturer: String?,
        model: String?,
        isPseudo: Bool = false,
        activeTaskCount: Int = 0,
        hostAssetID: UUID? = nil,
        hostName: String? = nil,
        attachments: [RanchOSPropertyAssetLink] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.location = location
        self.manufacturer = manufacturer
        self.model = model
        self.isPseudo = isPseudo
        self.activeTaskCount = isPseudo ? 0 : max(0, activeTaskCount)
        self.hostAssetID = hostAssetID
        self.hostName = hostName
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, location, manufacturer, model, host, attachments
        case isPseudo = "is_pseudo"
        case hostAssetID = "host_asset_id"
        case pmSummary = "pm_summary"
    }

    private struct PMSummary: Decodable {
        let activeTaskCount: Int?

        enum CodingKeys: String, CodingKey {
            case activeTaskCount = "active_task_count"
        }
    }

    private struct HostRef: Decodable {
        let name: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        isPseudo = try container.decodeIfPresent(Bool.self, forKey: .isPseudo) ?? false
        hostAssetID = try container.decodeIfPresent(UUID.self, forKey: .hostAssetID)
        hostName = try container.decodeIfPresent(HostRef.self, forKey: .host)?.name
        attachments = try container.decodeIfPresent([RanchOSPropertyAssetLink].self, forKey: .attachments) ?? []
        let summary = try container.decodeIfPresent(PMSummary.self, forKey: .pmSummary)
        activeTaskCount = isPseudo ? 0 : max(0, summary?.activeTaskCount ?? 0)
    }

    /// Real assets for the Property overview (excludes pseudo groups).
    static func summaryAssets(from assets: [Self]) -> [Self] {
        assets.filter { !$0.isPseudo }
    }

    /// Groups live assets by host. A pseudo group or host is the parent; hosted assets are its members.
    static func relationshipSummaries(from assets: [Self]) -> [RanchOSPropertyRelationshipSummary] {
        let ids = Set(assets.map(\.id))
        func directChildren(of hostID: UUID) -> [Self] {
            assets
                .filter { $0.hostAssetID == hostID && $0.id != hostID && ids.contains(hostID) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let roots = assets.filter { asset in
            guard let host = asset.hostAssetID, ids.contains(host), host != asset.id else { return true }
            return false
        }.sorted { lhs, rhs in
            if lhs.isPseudo != rhs.isPseudo { return lhs.isPseudo }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        func descendants(of hostID: UUID, seen: inout Set<UUID>) -> [Self] {
            var collected = [Self]()
            for child in directChildren(of: hostID) where seen.insert(child.id).inserted {
                collected.append(child)
                collected.append(contentsOf: descendants(of: child.id, seen: &seen))
            }
            return collected
        }
        return roots.map { root in
            let children = directChildren(of: root.id)
            let members = children.map { child in
                RanchOSPropertyRelationshipMember(
                    id: child.id,
                    name: child.name,
                    detail: child.memberDetail(includes: directChildren(of: child.id)))
            }
            var seen: Set<UUID> = [root.id]
            let related = descendants(of: root.id, seen: &seen)
            return RanchOSPropertyRelationshipSummary(
                id: root.id,
                title: root.name,
                detail: root.summaryDetail(related: related, knownHostIDs: ids),
                members: members)
        }
    }

    private func memberDetail(includes children: [Self]) -> String {
        guard !children.isEmpty else { return activeTasksLabel }
        let names = children.map(\.name).joined(separator: ", ")
        return "\(activeTasksLabel) · includes \(names)"
    }

    private func summaryDetail(related: [Self], knownHostIDs: Set<UUID>) -> String {
        if related.isEmpty {
            if let hostName, let hostAssetID, !knownHostIDs.contains(hostAssetID) {
                return "\(activeTasksLabel) · on \(hostName)"
            }
            return activeTasksLabel
        }
        let assetCount = related.count
        let assets = assetCount == 1 ? "1 asset" : "\(assetCount) assets"
        let taskTotal = related.reduce(activeTaskCount) { $0 + $1.activeTaskCount }
        let tasks = taskTotal == 1 ? "1 active task" : "\(taskTotal) active tasks"
        return "\(assets) · \(tasks)"
    }

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

struct RanchOSPropertyAssetRollup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let tasks: [RanchOSPropertyLiveTask]

    var taskCount: Int { tasks.count }
    var estimatedMinutes: Int { tasks.reduce(0) { $0 + ($1.estimatedMinutes ?? 0) } }
    var summary: String {
        let tasks = taskCount == 1 ? "1 task" : "\(taskCount) tasks"
        return "\(tasks) · \(RanchOSPropertyHours.label(minutes: estimatedMinutes))"
    }
}

enum RanchOSPropertyHours {
    static func label(minutes: Int) -> String {
        guard minutes > 0 else { return "0 hours" }
        if minutes.isMultiple(of: 60) {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return String(format: "%.1f hours", Double(minutes) / 60)
    }
}

enum RanchOSPropertyAssetRollupBuilder {
    static let unlinkedName = "Unlinked tasks"

    /// Active tasks consolidated by asset. Assets with no tasks stay in the list.
    /// A task whose asset is missing from a loaded asset list is not assigned to another asset.
    static func rollups(
        tasks: [RanchOSPropertyLiveTask],
        assets: [RanchOSPropertyLiveAsset]
    ) -> [RanchOSPropertyAssetRollup] {
        let known = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var tasksByKey: [String: [RanchOSPropertyLiveTask]] = [:]
        var names: [String: String] = [:]

        for asset in assets {
            let key = assetKey(asset.id)
            tasksByKey[key] = []
            names[key] = asset.name
        }

        for task in tasks where task.isActive {
            if let assetID = task.assetID, known[assetID] != nil {
                tasksByKey[assetKey(assetID), default: []].append(task)
            } else if task.assetID != nil, !assets.isEmpty {
                names[unlinkedName] = unlinkedName
                tasksByKey[unlinkedName, default: []].append(task)
            } else {
                let key = areaKey(task.area)
                names[key] = displayArea(task.area)
                tasksByKey[key, default: []].append(task)
            }
        }

        return names.keys.sorted { lhs, rhs in
            if (lhs == unlinkedName) != (rhs == unlinkedName) { return rhs == unlinkedName }
            let order = (names[lhs] ?? lhs).localizedCaseInsensitiveCompare(names[rhs] ?? rhs)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }.map { key in
            let name = names[key] ?? key
            let grouped = (tasksByKey[key] ?? []).sorted {
                displayTitle($0.title, group: name)
                    .localizedCaseInsensitiveCompare(displayTitle($1.title, group: name)) == .orderedAscending
            }
            return RanchOSPropertyAssetRollup(id: key, name: name, tasks: grouped)
        }
    }

    static func displayTitle(_ title: String, group: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = group.trimmingCharacters(in: .whitespacesAndNewlines) + ":"
        guard prefix != ":" else { return text }
        while text.lowercased().hasPrefix(prefix.lowercased()) {
            text = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t:-"))
        }
        return text.isEmpty ? title : text
    }

    private static func assetKey(_ id: UUID) -> String { "asset:" + id.uuidString.lowercased() }

    private static func areaKey(_ area: String) -> String { "area:" + displayArea(area).lowercased() }

    private static func displayArea(_ area: String) -> String {
        let trimmed = area.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Property" : trimmed
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
