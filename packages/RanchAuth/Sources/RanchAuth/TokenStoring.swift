import Foundation
import Security

/// Storage for one `AuthSession`. Keychain in the app, in-memory in tests.
public protocol TokenStoring: Sendable {
    func save(_ session: AuthSession) throws
    func load() throws -> AuthSession?
    func delete() throws
}

/// Keychain-backed token storage: one generic-password item per service.
public struct KeychainTokenStore: TokenStoring {
    private let service: String
    private let account = "session"

    public init(service: String = "ai.openclaw.ranchauth") {
        self.service = service
    }

    public func save(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = baseQuery()
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = [kSecValueData as String: data] as CFDictionary
            try check(SecItemUpdate(query as CFDictionary, update))
        } else if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            try check(SecItemAdd(add as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func load() throws -> AuthSession? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data else { return nil }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AuthError.keychainFailure("OSStatus \(status)")
        }
    }
}

/// Non-persistent store for previews and unit tests.
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AuthSession?

    public init(session: AuthSession? = nil) {
        self.stored = session
    }

    public func save(_ session: AuthSession) throws {
        lock.withLock { stored = session }
    }

    public func load() throws -> AuthSession? {
        lock.withLock { stored }
    }

    public func delete() throws {
        lock.withLock { stored = nil }
    }
}
