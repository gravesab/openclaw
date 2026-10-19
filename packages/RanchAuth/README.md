# RanchAuth

Standalone Swift package: Sign in with Apple + Google Sign-In (SPM),
Keychain token storage, `ASWebAuthenticationSession` browser fallback,
and an `AuthGate` that protects `ContentView`.

No existing app is touched. Add it to any app or keep it standalone.

## Add to an app

```swift
import RanchAuth

@main
struct MyApp: App {
    @State private var auth = AuthManager(
        config: AuthConfiguration(googleClientID: "YOUR_GOOGLE_CLIENT_ID")
    )

    var body: some Scene {
        WindowGroup {
            AuthGate(auth: auth) {
                ContentView()
            }
        }
    }
}
```

Sign out from anywhere: `auth.signOut()`.

## Setup

1. Add the package (Xcode → Package Dependencies) or reference this
   directory from another `Package.swift`.
2. Google: set `AuthConfiguration.googleClientID`, or add the
   `GIDClientID` key to Info.plist plus the
   `com.googleusercontent.apps.<client-id>` URL scheme. Without it,
   Google sign-in throws a descriptive error instead of failing silently.
3. Apple: enable the Sign in with Apple capability for the app target.
   No server or token endpoint is needed for the client side.
4. Keychain: no entitlement is required for the default
   `kSecAttrAccessibleAfterFirstUnlock` item; enable Keychain Sharing
   only to share the session across the app group.
5. Browser sign-in is opt-in: `SignInView` shows it only when
   `showsBrowserSignIn` is set with an `authorizeURL` and callback
   scheme. Validate any browser-returned token on the server.

## Notes

- The Google path compiles only when the `GoogleSignIn` product
  resolves (`#if canImport(GoogleSignIn)`); everything else builds
  without it.
- `ASWebAuthenticationSession` uses an ephemeral browser session, so
  no cookies persist.
- First Apple sign-in returns name and email; later ones return only
  the stable user id. Persist what the app needs on first sign-in.
