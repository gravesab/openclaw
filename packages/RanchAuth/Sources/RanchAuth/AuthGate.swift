import AuthenticationServices
import SwiftUI

/// Shows `Content` only while signed in; otherwise the sign-in screen.
/// Wrap the app's content view to protect it:
/// `AuthGate(auth: auth) { ContentView() }`.
public struct AuthGate<Content: View>: View {
    @Bindable var auth: AuthManager
    @ViewBuilder var content: () -> Content

    public init(auth: AuthManager, @ViewBuilder content: @escaping () -> Content) {
        self.auth = auth
        self.content = content
    }

    public var body: some View {
        switch auth.state {
        case .signedIn:
            content()
        case .signingIn:
            ProgressView("Signing in…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            SignInView(auth: auth)
        }
    }
}

/// Provider buttons for every supported sign-in path.
public struct SignInView: View {
    @Bindable var auth: AuthManager
    var showsBrowserSignIn: Bool = false
    var authorizeURL: URL? = nil
    var callbackScheme: String = ""

    public init(auth: AuthManager) {
        self.auth = auth
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Sign in")
                .font(.largeTitle.bold())
            if let error = auth.lastError {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            SignInWithAppleButton(.signIn) { _ in
                Task { try? await auth.signInWithApple() }
            } onCompletion: { result in
                if case .failure(let error) = result {
                    auth.note(error)
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .accessibilityLabel("Sign in with Apple")

            Button {
                Task { try? await auth.signInWithGoogle() }
            } label: {
                Label("Sign in with Google", systemImage: "g.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Sign in with Google")

            if showsBrowserSignIn, let url = authorizeURL {
                Button {
                    Task { try? await auth.signInWithBrowser(authorizeURL: url, callbackScheme: callbackScheme) }
                } label: {
                    Label("Sign in with browser", systemImage: "safari")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Sign in with browser")
            }
        }
        .padding(24)
    }
}

extension AuthManager {
    /// Records a provider-completion failure without changing state.
    func note(_ error: Error) {
        if let authError = error as? AuthError {
            lastError = authError
        } else {
            lastError = .providerError(error.localizedDescription)
        }
        if case .signingIn = state {
            state = .signedOut
        }
    }
}

#Preview {
    AuthGate(auth: AuthManager(config: AuthConfiguration(), store: InMemoryTokenStore())) {
        Text("ContentView goes here")
    }
}
