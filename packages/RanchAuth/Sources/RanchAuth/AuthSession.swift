import Foundation

/// A signed-in session, Codable so it can live in the Keychain.
public struct AuthSession: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case apple
        case google
        case browser
    }

    public var provider: Provider
    public var userID: String
    public var idToken: String
    public var email: String?
    public var name: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(
        provider: Provider,
        userID: String,
        idToken: String,
        email: String? = nil,
        name: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.provider = provider
        self.userID = userID
        self.idToken = idToken
        self.email = email
        self.name = name
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True when the session carries an expiry that has passed.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    /// Builds a session from a browser OAuth callback URL, reading
    /// `id_token` (or `access_token`) plus `sub`/`email` from the query
    /// or fragment. Servers should still verify the token themselves.
    public static func browser(callbackURL: URL) throws -> AuthSession {
        var items: [URLQueryItem] = []
        if let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) {
            items += components.queryItems ?? []
            if let fragment = components.fragment {
                var fragmentComponents = URLComponents()
                fragmentComponents.query = fragment
                items += fragmentComponents.queryItems ?? []
            }
        }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let token = value("id_token") ?? value("access_token") else {
            throw AuthError.missingToken
        }
        guard let subject = value("sub") ?? value("email") else {
            throw AuthError.missingToken
        }
        return AuthSession(
            provider: .browser,
            userID: subject,
            idToken: token,
            email: value("email")
        )
    }
}

/// Configuration for every provider. The Google client ID comes from the
/// Google Cloud console; keep it in Info.plist under `GIDClientID` or pass
/// it here.
public struct AuthConfiguration: Sendable {
    public var googleClientID: String?
    public var keychainService: String

    public init(googleClientID: String? = nil, keychainService: String = "ai.openclaw.ranchauth") {
        self.googleClientID = googleClientID
        self.keychainService = keychainService
    }
}

public enum AuthError: Error, LocalizedError, Equatable {
    case cancelled
    case missingToken
    case missingPresenter
    case providerUnavailable(String)
    case providerError(String)
    case keychainFailure(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .missingToken: "The provider did not return an identity token."
        case .missingPresenter: "No window is available to present sign-in."
        case .providerUnavailable(let name): "\(name) sign-in is not available in this build."
        case .providerError(let message): message
        case .keychainFailure(let message): "Keychain error: \(message)."
        }
    }
}
