import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Presentation anchors and native presenters for auth UI.
enum Presenter {
    /// Window or anchor for `ASWebAuthenticationSession` and Apple sign-in.
    static func anchor() -> ASPresentationAnchor {
        #if os(iOS)
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window
        }
        return ASPresentationAnchor()
        #elseif os(macOS)
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }

    #if os(iOS)
    /// Root view controller for `GIDSignIn.signIn(withPresenting:)`.
    static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
    }
    #endif
}

/// `ASWebAuthenticationSession` bridged to async/await, for OAuth
/// providers without a native SDK path. Retained by the caller for the
/// duration of the `start` await.
@MainActor
final class WebAuthSession: NSObject {
    private var retained: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    /// Runs the session and returns the callback URL carrying the tokens.
    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.finish(with: callbackURL, error: error)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.retained = session
            if !session.start() {
                self.finish(with: nil, error: AuthError.providerError("The browser session could not start."))
            }
        }
    }

    private func finish(with callbackURL: URL?, error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        self.retained = nil
        if let callbackURL {
            continuation?.resume(returning: callbackURL)
        } else if let error = error as? ASWebAuthenticationSessionError,
                  error.code == .canceledLogin {
            continuation?.resume(throwing: AuthError.cancelled)
        } else {
            continuation?.resume(throwing: AuthError.providerError(error?.localizedDescription ?? "Browser sign-in failed."))
        }
    }
}

extension WebAuthSession: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            Presenter.anchor()
        }
    }
}
