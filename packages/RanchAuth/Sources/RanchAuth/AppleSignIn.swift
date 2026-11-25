import AuthenticationServices
import CryptoKit
import Foundation

/// Sign in with Apple, bridged to async/await. Retained by the caller
/// for the duration of the `authorize` await.
@MainActor
final class AppleSignInCoordinator: NSObject {
    private var continuation: CheckedContinuation<AuthSession, Error>?

    func authorize() async throws -> AuthSession {
        let nonce = Nonce.make()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<AuthSession, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8)
        else {
            Task { @MainActor in
                self.finish(.failure(AuthError.missingToken))
            }
            return
        }
        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
        let session = AuthSession(
            provider: .apple,
            userID: credential.user,
            idToken: idToken,
            email: credential.email,
            name: name.isEmpty ? nil : name
        )
        Task { @MainActor in
            self.finish(.success(session))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let authError: AuthError
        if let authServiceError = error as? ASAuthorizationError,
           authServiceError.code == .canceled {
            authError = .cancelled
        } else {
            authError = .providerError(error.localizedDescription)
        }
        Task { @MainActor in
            self.finish(.failure(authError))
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            Presenter.anchor()
        }
    }
}

enum Nonce {
    static func make(length: Int = 32) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else { continue }
            if random < alphabet.count {
                result.append(alphabet[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
