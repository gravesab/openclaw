import XCTest
@testable import RanchAuth

final class RanchAuthTests: XCTestCase {
    @MainActor
    func testSessionCodableRoundTrip() throws {
        let session = AuthSession(
            provider: .apple,
            userID: "user-1",
            idToken: "token-abc",
            email: "sam@ranchos.dev",
            name: "Sam"
        )
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.self, from: data), session)
    }

    @MainActor
    func testBrowserCallbackParsesFragmentToken() throws {
        let url = URL(string: "ranchauth://oauth#id_token=frag-token&sub=user-9")!
        let session = try AuthSession.browser(callbackURL: url)
        XCTAssertEqual(session.provider, .browser)
        XCTAssertEqual(session.idToken, "frag-token")
        XCTAssertEqual(session.userID, "user-9")
    }

    @MainActor
    func testBrowserCallbackParsesQueryToken() throws {
        let url = URL(string: "ranchauth://oauth?access_token=at-1&email=jo@ranchos.dev")!
        let session = try AuthSession.browser(callbackURL: url)
        XCTAssertEqual(session.idToken, "at-1")
        XCTAssertEqual(session.userID, "jo@ranchos.dev")
        XCTAssertEqual(session.email, "jo@ranchos.dev")
    }

    @MainActor
    func testBrowserCallbackWithoutTokenFails() {
        let url = URL(string: "ranchauth://oauth?error=access_denied")!
        XCTAssertThrowsError(try AuthSession.browser(callbackURL: url))
    }

    @MainActor
    func testInMemoryStoreSaveLoadDelete() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())
        let session = AuthSession(provider: .google, userID: "u", idToken: "t")
        try store.save(session)
        XCTAssertEqual(try store.load(), session)
        try store.delete()
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testManagerRestoresSavedSessionAndSignOutClears() throws {
        let session = AuthSession(provider: .apple, userID: "u", idToken: "t")
        let store = InMemoryTokenStore(session: session)
        let auth = AuthManager(store: store)
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.session, session)
        auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(try store.load())
    }

    @MainActor
    func testManagerStartsSignedOutWithEmptyStore() {
        let auth = AuthManager(store: InMemoryTokenStore())
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(auth.session)
    }
}
