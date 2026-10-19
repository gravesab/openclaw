import XCTest

final class RanchOSRuntimeEnvironmentTests: XCTestCase {
    func testDevelopmentAndProductionKeepSeparatePropertyHostsAndKeychainSlots() {
        let development = RanchOSRuntimeEnvironment.development
        let production = RanchOSRuntimeEnvironment.production

        XCTAssertNotEqual(development.propertyBaseURL, production.propertyBaseURL)
        XCTAssertNotEqual(development.propertyKeychainService, production.propertyKeychainService)
        XCTAssertNotEqual(development.propertyKeychainAccount, production.propertyKeychainAccount)
        XCTAssertNotEqual(development.propertyLaunchKeyEnvironment, production.propertyLaunchKeyEnvironment)
        XCTAssertEqual(development.propertyLaunchKeyEnvironment, "RANCHOS_PROPERTYMANAGER_DEV_API_KEY")
        XCTAssertEqual(production.propertyLaunchKeyEnvironment, "RANCHOS_PROPERTYMANAGER_PROD_API_KEY")
        XCTAssertTrue(development.propertyBaseURL.absoluteString.contains("5062") || development.propertyBaseURL.absoluteString.contains("15063"))
        XCTAssertTrue(production.propertyBaseURL.absoluteString.contains("5062"))
        XCTAssertFalse(development.propertyBaseURL.absoluteString.contains("100.85.36.72"))
        XCTAssertFalse(production.propertyKeychainService.contains(".dev."))
        XCTAssertFalse(development.propertyKeychainService.contains(".prod."))
    }

    func testBuildIdentityNamesTheChosenEnvironmentNextToVersionAndBuild() {
        XCTAssertEqual(RanchOSRuntimeEnvironment.development.productName, "RanchOS DEV")
        XCTAssertEqual(RanchOSRuntimeEnvironment.production.productName, "RanchOS Production")
        XCTAssertTrue(
            RanchOSBuildInfo.display(for: .development).hasPrefix("RanchOS DEV · Version "),
            RanchOSBuildInfo.display(for: .development))
        XCTAssertTrue(
            RanchOSBuildInfo.display(for: .production).hasPrefix("RanchOS Production · Version "),
            RanchOSBuildInfo.display(for: .production))
        XCTAssertTrue(RanchOSBuildInfo.accessibilityLabel(for: .production).contains("production"))
        XCTAssertTrue(RanchOSBuildInfo.accessibilityLabel(for: .production).contains("Version"))
        XCTAssertTrue(RanchOSBuildInfo.accessibilityLabel(for: .production).contains("Build"))
    }

    func testLivestockAndFinanceStayDisconnectedUntilThoseReadAPIsExist() {
        XCTAssertTrue(RanchOSRuntimeEnvironment.development.livestockPendingLabel.contains("pending"))
        XCTAssertTrue(RanchOSRuntimeEnvironment.production.livestockPendingLabel.contains("not available"))
        XCTAssertTrue(RanchOSFinanceDashboard.disconnectedBanner.contains("not connected"))
        XCTAssertFalse(RanchOSLivestockConnection.pending.hasAuthorizedProvider)
        XCTAssertFalse(RanchOSLivestockConnection().hasAuthorizedProvider)
    }
}
