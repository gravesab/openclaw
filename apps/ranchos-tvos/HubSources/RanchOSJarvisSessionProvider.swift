import AuthenticationServices
import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// DEV session constants and pure OAuth helpers for the Jarvis live-session
/// slice. No UI, no stored credentials. This file is a member of the iOS,
/// macOS, and HubTests targets only: ASWebAuthenticationSession does not
/// exist on tvOS, so tvOS compiles no sign-in control.
enum RanchOSJarvisDevSession {
    /// The single tenant row in ranchos_livestock_dev on SSH-Dev. Sent as
    /// X-Ranch-Tenant on POST /v1/session; an empty header is HTTP 400.
    static let tenantID = "11111111-2222-4333-8444-555555555501"

    static let serviceBaseURL = URL(string: "http://100.85.188.74:5063")!
    static let googleAuthorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let googleTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static let scope = "openid email"
    static let maxAgeSeconds = 300
    static let redirectPath = "/oauth2redirect"

    /// Requested on every authorization call. max_age alone does not return
    /// these claims; they must also be turned on in Google Auth Platform.
    static let claimsParameter = #"{"id_token":{"auth_time":{"essential":true},"amr":{"essential":true}}}"#

    private static let clientIDSuffix = ".apps.googleusercontent.com"
    private static let schemePrefix = "com.googleusercontent.apps."

    /// Reversed-client-id custom scheme for an iOS OAuth client id.
    static func callbackScheme(clientID: String) -> String? {
        guard clientID.hasSuffix(clientIDSuffix) else { return nil }
        let core = clientID.dropLast(clientIDSuffix.count)
        guard !core.isEmpty else { return nil }
        return schemePrefix + core
    }

    static func clientID(callbackScheme scheme: String) -> String? {
        guard scheme.hasPrefix(schemePrefix) else { return nil }
        let core = scheme.dropFirst(schemePrefix.count)
        guard !core.isEmpty else { return nil }
        return core + clientIDSuffix
    }

    static func redirectURI(callbackScheme scheme: String) -> String {
        scheme + ":" + redirectPath
    }

    static func authorizationURL(
        clientID: String,
        callbackScheme scheme: String,
        state: String,
        nonce: String,
        verifier: String
    ) -> URL? {
        var components = URLComponents(url: googleAuthorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI(callbackScheme: scheme)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "max_age", value: String(maxAgeSeconds)),
            URLQueryItem(name: "code_challenge", value: pkceChallenge(verifier: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "claims", value: claimsParameter),
        ]
        return components?.url
    }

    /// S256 PKCE challenge: base64url(SHA-256(verifier)) without padding.
    static func pkceChallenge(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func randomVerifier() -> String {
        randomString(length: 64)
    }

    static func randomString(length: Int = 32) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return (0..<length).map { _ in String(alphabet[Int.random(in: 0..<alphabet.count)]) }.joined()
        }
        return bytes.map { String(alphabet[Int($0) % alphabet.count]) }.joined()
    }

    /// Extracts the authorization code from the browser callback. Throws
    /// `.denied` when the user refused, `.badCallback` otherwise.
    static func authorizationCode(callbackURL: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var values: [String: String] = [:]
        for item in items {
            if let value = item.value { values[item.name] = value }
        }
        if values["error"] != nil { throw RanchOSJarvisSignInError.denied }
        guard let code = values["code"], !code.isEmpty,
            values["state"] == expectedState
        else {
            throw RanchOSJarvisSignInError.badCallback
        }
        return code
    }
}

/// Live Google sign-in: system browser plus PKCE, code exchange over
/// URLSession, then the existing issueSession. The Google ID token stays a
/// function-local single-use value; only the `rbs_` session is stored, by the
/// client, in the shared memory-only holder. Nothing here is logged.
@MainActor
final class RanchOSJarvisLiveSessionProvider: RanchOSJarvisSessionSigning, Sendable {
    private let client: RanchBrainClient
    private let transport: any RanchBrainHTTPTransport
    private let fixedConfig: (clientID: String, scheme: String)?
    private var webSession: ASWebAuthenticationSession?
    private var inFlight = false

    /// Test seam: maps (authURL, scheme) to an authorization code. The default
    /// runs the real system browser; tests inject a fake code.
    var authCodeRunner: @Sendable (URL, String) async throws -> String

    init(
        client: RanchBrainClient,
        transport: any RanchBrainHTTPTransport = RanchBrainURLSessionTransport(session: .shared),
        clientConfig: (clientID: String, scheme: String)? = nil,
        authCodeRunner: (@Sendable (URL, String) async throws -> String)? = nil
    ) {
        self.client = client
        self.transport = transport
        self.fixedConfig = clientConfig
        if let authCodeRunner {
            self.authCodeRunner = authCodeRunner
        } else {
            self.authCodeRunner = { _, _ in throw RanchOSJarvisSignInError.transport }
            self.authCodeRunner = { [weak self] url, scheme in
                guard let self else { throw RanchOSJarvisSignInError.cancelled }
                return try await self.runSystemBrowser(authURL: url, callbackScheme: scheme)
            }
        }
    }

    func signIn() async throws -> RanchBrainSession {
        guard !inFlight else { throw RanchOSJarvisSignInError.alreadySigningIn }
        guard let (clientID, scheme) = fixedConfig ?? Self.googleClientConfig() else {
            throw RanchOSJarvisSignInError.misconfigured
        }
        let verifier = RanchOSJarvisDevSession.randomVerifier()
        let state = RanchOSJarvisDevSession.randomString()
        let nonce = RanchOSJarvisDevSession.randomString()
        guard let authURL = RanchOSJarvisDevSession.authorizationURL(
            clientID: clientID, callbackScheme: scheme, state: state, nonce: nonce, verifier: verifier)
        else {
            throw RanchOSJarvisSignInError.misconfigured
        }
        inFlight = true
        defer {
            inFlight = false
            webSession = nil
        }
        let code: String
        do {
            code = try await authCodeRunner(authURL, scheme)
        } catch is CancellationError {
            throw RanchOSJarvisSignInError.cancelled
        }
        let idToken = try await exchangeCode(code, verifier: verifier, clientID: clientID, scheme: scheme)
        do {
            return try await client.issueSession(
                googleToken: idToken, tenantID: RanchOSJarvisDevSession.tenantID)
        } catch let error as RanchBrainError {
            switch error {
            case .unauthorized:
                throw RanchOSJarvisSignInError.unauthorized
            case .server(let status, _) where status == 403:
                throw RanchOSJarvisSignInError.forbiddenNotLinked
            default:
                throw RanchOSJarvisSignInError.transport
            }
        }
    }

    func cancelSignIn() {
        webSession?.cancel()
    }

    func signOut() async {
        await client.purge()
    }

    /// Reads the registered Google callback scheme and derives the client id
    /// back from it, so the id appears in exactly one place: the plist the OS
    /// requires. Returns nil when no Google scheme is registered.
    nonisolated static func googleClientConfig(bundle: Bundle = .main) -> (clientID: String, scheme: String)? {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        for type in types {
            let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
            for scheme in schemes {
                if let clientID = RanchOSJarvisDevSession.clientID(callbackScheme: scheme) {
                    return (clientID, scheme)
                }
            }
        }
        return nil
    }

    private func exchangeCode(
        _ code: String, verifier: String, clientID: String, scheme: String
    ) async throws -> String {
        var request = URLRequest(url: RanchOSJarvisDevSession.googleTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: RanchOSJarvisDevSession.redirectURI(callbackScheme: scheme)),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw RanchOSJarvisSignInError.transport
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RanchOSJarvisSignInError.tokenExchangeFailed
        }
        struct TokenResponse: Decodable {
            var idToken: String?
            private enum CodingKeys: String, CodingKey {
                case idToken = "id_token"
            }
        }
        guard let idToken = (try? JSONDecoder().decode(TokenResponse.self, from: data))?.idToken,
            !idToken.isEmpty
        else {
            throw RanchOSJarvisSignInError.tokenExchangeFailed
        }
        return idToken
    }

    private func runSystemBrowser(authURL: URL, callbackScheme scheme: String) async throws -> String {
        let expectedState = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        guard let anchor = Self.presentationAnchor() else {
            throw RanchOSJarvisSignInError.noPresentationAnchor
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            func resume(_ result: Result<String, RanchOSJarvisSignInError>) {
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let code): continuation.resume(returning: code)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            let session = ASWebAuthenticationSession(
                url: authURL, callbackURLScheme: scheme
            ) { url, error in
                if let sessionError = error as? ASWebAuthenticationSessionError,
                    sessionError.code == .canceledLogin
                {
                    resume(.failure(.cancelled))
                    return
                }
                if error != nil {
                    resume(.failure(.transport))
                    return
                }
                guard let url else {
                    resume(.failure(.badCallback))
                    return
                }
                do {
                    let code = try RanchOSJarvisDevSession.authorizationCode(
                        callbackURL: url, expectedState: expectedState)
                    resume(.success(code))
                } catch let error as RanchOSJarvisSignInError {
                    resume(.failure(error))
                } catch {
                    resume(.failure(.badCallback))
                }
            }
            session.presentationContextProvider = RanchOSJarvisAuthAnchorProvider(anchor: anchor)
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            guard session.start() else {
                resume(.failure(.transport))
                return
            }
        }
    }

#if os(iOS)
    private static func presentationAnchor() -> ASPresentationAnchor? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
#else
    private static func presentationAnchor() -> ASPresentationAnchor? {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
    }
#endif
}

/// Holds the presentation anchor across the ASWebAuthenticationSession
/// boundary. The anchor is captured before the session starts and only read
/// from the provider callback.
private final class RanchOSJarvisAuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
