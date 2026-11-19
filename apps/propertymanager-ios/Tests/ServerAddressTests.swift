import XCTest
@testable import PropertyManager

final class ServerAddressTests: XCTestCase {
    private let tailscale = "http://100.85.36.72:5062"
    private let others = ["http://192.168.50.104:5062", "http://intelmini.local:5062"]

    @MainActor
    func testTheBuiltInAddressIsUsedAndATypedAddressIsKeptAsIs() {
        XCTAssertEqual(PropertyStore.baseURL(stored: "http://100.85.36.72:5062/", builtIn: tailscale, otherAddresses: others), tailscale)
        XCTAssertEqual(PropertyStore.baseURL(stored: " http://10.0.0.9:5062 ", builtIn: tailscale, otherAddresses: others), "http://10.0.0.9:5062")
    }

    /// Older builds saved the Intel Mini's Wi-Fi IP or .local name. Both fail off the ranch, and the
    /// .local name can be spoofed on any Wi-Fi, so they must resolve to the Tailscale address.
    @MainActor
    func testSavedWiFiAndLocalAddressesOfTheBuiltInServerUseTailscale() {
        for saved in ["http://192.168.50.104:5062", "http://intelmini.local:5062/", " http://intelmini.local:5062 "] {
            XCTAssertTrue(PropertyStore.isBuiltInServer(stored: saved, builtIn: tailscale, otherAddresses: others), saved)
            XCTAssertEqual(PropertyStore.baseURL(stored: saved, builtIn: tailscale, otherAddresses: others), tailscale, saved)
        }
    }

    func testNoBuiltInAddressUsesALocalHostName() {
        typealias Env = PropertyManagerBuildEnvironment
        for address in [Env.apiBaseURL, Env.manualLibraryBaseURL] {
            XCTAssertFalse(URL(string: address)?.host?.hasSuffix(".local") ?? true, address)
        }
    }
}
