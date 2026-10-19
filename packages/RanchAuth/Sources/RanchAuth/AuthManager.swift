import Foundation
import Observation
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
#if os(macOS)
import AppKit
#endif

/// One observable sign-in state for the whole app. Owns the Keychain
/// session: sign-in saves it, sign-out deletes it, init restores it.
@MainActor
@Observable
public final class AuthManager {
    public enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(AuthSession)
    }

    public internal(set) var state: State = .signedOut
    public internal(set) var lastError: AuthError?

    private let config: AuthConfiguration
    private let store: any TokenStoring

    public init(config: AuthConfiguration = AuthConfiguration(), store: (any TokenStoring)? = nil) {
        self.config = config
        self.store = store ?? KeychainTokenStore(service: config.keychainService)
        restore()
    }

    public var session: AuthSession? {
        if case .signedIn(let session) = state { session } else { nil }
    }

    public var isSignedIn: Bool { session != nil }

    /// Reload the Keychain session, if any.
    public func restore() {
        if let saved = try? store.load() {
            state = .signedIn(saved)
        } else {
            state = .signedOut
        }
    }

    /// Sign in with Apple. Shows the system sheet; nothing leaves the device except Apple's own flow.
    public func signInWithApple() async throws {
        state = .signingIn
        lastError = nil
        do {
            let session = try await AppleSignInCoordinator().authorize()
            try store.save(session)
            state = .signedIn(session)
        } catch let error as AuthError {
            state = .signedOut
            lastError = error
            throw error
        }
    }

    /// Sign in with Google via the GoogleSignIn SPM SDK.
    public func signInWithGoogle() async throws {
        #if canImport(GoogleSignIn)
        guard let clientID = config.googleClientID ?? Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty
        else {
            throw fail(.providerError("Missing Google client ID. Set AuthConfiguration.googleClientID or the GIDClientID Info.plist key."))
        }
        state = .signingIn
        lastError = nil
        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let user = try await signInWithGooglePresenting().user
            guard let idToken = user.idToken?.tokenString else {
                throw AuthError.missingToken
            }
            let session = AuthSession(
                provider: .google,
                userID: user.userID ?? idToken,
                idToken: idToken,
                email: user.profile?.email,
                name: user.profile?.name,
                accessToken: user.accessToken.tokenString,
                refreshToken: user.refreshToken.tokenString,
                expiresAt: user.accessToken.expirationDate
            )
            try store.save(session)
            state = .signedIn(session)
        } catch let error as AuthError {
            state = .signedOut
            lastError = error
            throw error
        }
        #else
        throw fail(.providerUnavailable("Google"))
        #endif
    }

    /// Generic OAuth via `ASWebAuthenticationSession`. The callback URL
    /// must carry `id_token` (or `access_token`) in its query or fragment.
    /// Prefer a server-minted session here; the client never trusts raw tokens.
    public func signInWithBrowser(authorizeURL: URL, callbackScheme: String) async throws {
        state = .signingIn
        lastError = nil
        do {
            let callback = try await WebAuthSession().start(url: authorizeURL, callbackScheme: callbackScheme)
            let session = try AuthSession.browser(callbackURL: callback)
            try store.save(session)
            state = .signedIn(session)
        } catch let error as AuthError {
            state = .signedOut
            lastError = error
            throw error
        }
    }

    /// Signs out everywhere: Google SDK, Keychain, and in-memory state.
    public func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        try? store.delete()
        state = .signedOut
        lastError = nil
    }

    #if canImport(GoogleSignIn)
    private func signInWithGooglePresenting() async throws -> GIDSignInResult {
        #if os(iOS)
        guard let presenter = Presenter.rootViewController() else {
            throw AuthError.missingPresenter
        }
        do {
            return try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        } catch {
            throw googleError(error)
        }
        #elseif os(macOS)
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else {
            throw AuthError.missingPresenter
        }
        do {
            return try await GIDSignIn.sharedInstance.signIn(withPresenting: window)
        } catch {
            throw googleError(error)
        }
        #endif
    }

    private func googleError(_ error: Error) -> AuthError {
        let nsError = error as NSError
        if nsError.domain == "com.google.GIDSignIn", nsError.code == -5 {
            return .cancelled
        }
        return .providerError(error.localizedDescription)
    }
    #endif

    @discardableResult
    private func fail(_ error: AuthError) -> AuthError {
        state = .signedOut
        lastError = error
        return error
    }
}
