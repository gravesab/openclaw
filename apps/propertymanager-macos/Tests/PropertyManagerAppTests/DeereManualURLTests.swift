import XCTest
@testable import PropertyManagerApp

final class DeereManualURLTests: XCTestCase {
    private let suppliedURL = URL(string: "http://manuals.deere.com/omview/OMLVU28480_19/?tM=")!

    /// Body returned by HTTP GET of the supplied directory URL on 2026-09-27.
    private let suppliedFrameset = """
    <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
    <html>
    <head>
    <META http-equiv="Content-Type" content="text/html; charset=ISO-8859-1">
    <title>OMLVU28480</title>
    <script src="../includes/OmvPrint.js" type="text/javascript"></script>
    </head>
    <frameset cols="27%, *">
    <frame src="toc.html" name="toc">
    <frame src="mainone.html" name="main">
    </frameset>
    </html>
    """

    func testSuppliedDirectoryURLResolvesSameHostTOCAndRejectsEscape() {
        let toc = URLManualFetcher.preferredTOCFrameURL(in: suppliedFrameset, manualPage: suppliedURL)
        XCTAssertEqual(
            toc?.absoluteString,
            "http://manuals.deere.com/omview/OMLVU28480_19/toc.html"
        )
        XCTAssertEqual(toc?.scheme, "http")
        XCTAssertEqual(toc?.host, "manuals.deere.com")

        let main = URLManualFetcher.resolvedManualFrameURL("mainone.html", manualPage: suppliedURL)
        XCTAssertEqual(
            main?.absoluteString,
            "http://manuals.deere.com/omview/OMLVU28480_19/mainone.html"
        )
        XCTAssertNotEqual(toc, main)

        XCTAssertNil(
            URLManualFetcher.resolvedManualFrameURL("../includes/OmvPrint.js", manualPage: suppliedURL)
        )
        XCTAssertNil(
            URLManualFetcher.resolvedManualFrameURL("https://evil.example/toc.html", manualPage: suppliedURL)
        )
        XCTAssertNil(
            URLManualFetcher.resolvedManualFrameURL("http://www.manuals.deere.com/omview/OMLVU28480_19/toc.html", manualPage: suppliedURL)
        )
        XCTAssertNil(
            URLManualFetcher.preferredTOCFrameURL(
                in: #"<frame src="mainone.html" name="main">"#,
                manualPage: suppliedURL
            )
        )
    }

    func testURLHandlingDoesNotUpgradeOrDowngradeScheme() {
        let httpsPage = URL(string: "https://manuals.deere.com/omview/OMLVU28480_19/")!
        let resolved = URLManualFetcher.resolvedManualFrameURL("toc.html", manualPage: httpsPage)
        XCTAssertEqual(resolved?.scheme, "https")
        XCTAssertEqual(
            resolved?.absoluteString,
            "https://manuals.deere.com/omview/OMLVU28480_19/toc.html"
        )

        let absoluteHTTPS = URLManualFetcher.resolvedManualFrameURL(
            "https://manuals.deere.com/omview/OMLVU28480_19/toc.html",
            manualPage: suppliedURL
        )
        XCTAssertEqual(absoluteHTTPS?.scheme, "https")

        XCTAssertNil(
            URLManualFetcher.resolvedManualFrameURL(
                "http://manuals.deere.com/omview/OMLVU28480_19/toc.html",
                manualPage: httpsPage
            )
        )
    }

    func testRedirectAndFrameBoundsRejectEscapeDowngradeUserinfoAndUnexpectedPorts() {
        let toc = URL(string: "http://manuals.deere.com/omview/OMLVU28480_19/toc.html")!
        XCTAssertTrue(URLManualFetcher.allowsBoundedNavigation(toc, from: suppliedURL))

        XCTAssertFalse(
            URLManualFetcher.allowsBoundedNavigation(
                URL(string: "http://evil.example/omview/OMLVU28480_19/toc.html")!,
                from: suppliedURL
            )
        )
        XCTAssertFalse(
            URLManualFetcher.allowsBoundedNavigation(
                URL(string: "http://manuals.deere.com/omview/includes/OmvPrint.js")!,
                from: suppliedURL
            )
        )
        XCTAssertFalse(
            URLManualFetcher.allowsBoundedNavigation(
                URL(string: "http://user:secret@manuals.deere.com/omview/OMLVU28480_19/toc.html")!,
                from: suppliedURL
            )
        )
        XCTAssertFalse(
            URLManualFetcher.allowsBoundedNavigation(
                URL(string: "http://manuals.deere.com:8080/omview/OMLVU28480_19/toc.html")!,
                from: suppliedURL
            )
        )

        let httpsPage = URL(string: "https://manuals.deere.com/omview/OMLVU28480_19/")!
        XCTAssertFalse(
            URLManualFetcher.allowsBoundedNavigation(
                URL(string: "http://manuals.deere.com/omview/OMLVU28480_19/toc.html")!,
                from: httpsPage
            )
        )
        XCTAssertTrue(
            URLManualFetcher.allowsBoundedNavigation(
                URL(string: "https://manuals.deere.com/omview/OMLVU28480_19/toc.html")!,
                from: suppliedURL
            )
        )
    }

    func testUnchangedExtensionlessSectionURLRemainsAcceptable() {
        let section = URL(string: "https://example.com/manual")!
        XCTAssertEqual(URLManualFetcher.manualDirectoryPath(for: section), "/manual/")
        XCTAssertFalse(section.path.hasPrefix("/manual/"))
        XCTAssertTrue(URLManualFetcher.isUnchangedRequestedURL(section, requested: section))
        XCTAssertEqual(URLManualFetcher.acceptedFetchedURL(section, requested: section), section)

        XCTAssertTrue(
            URLManualFetcher.allowsBoundedNavigation(
                URL(string: "https://example.com/manual/oil.html")!,
                from: section
            )
        )
        XCTAssertNil(
            URLManualFetcher.acceptedFetchedURL(
                URL(string: "https://example.com/other")!,
                requested: section
            )
        )
        XCTAssertNil(
            URLManualFetcher.resolvedManualFrameURL("toc.html", manualPage: section)
        )
    }

    func testRedirectChainRejectsHTTPDowngradeAfterHTTPSUpgrade() {
        let origin = URL(string: "http://example.com/manual")!
        let upgraded = URL(string: "https://example.com/manual")!
        XCTAssertTrue(URLManualFetcher.allowsRedirect(upgraded, from: origin, immediateResponse: origin))
        XCTAssertFalse(
            URLManualFetcher.allowsRedirect(origin, from: origin, immediateResponse: upgraded)
        )

        let frame = URL(string: "http://manuals.deere.com/omview/OMLVU28480_19/toc.html")!
        let frameHTTPS = URL(string: "https://manuals.deere.com/omview/OMLVU28480_19/toc.html")!
        XCTAssertTrue(URLManualFetcher.allowsRedirect(frameHTTPS, from: frame, immediateResponse: frame))
        XCTAssertFalse(
            URLManualFetcher.allowsRedirect(frame, from: frame, immediateResponse: frameHTTPS)
        )
        XCTAssertFalse(
            URLManualFetcher.allowsRedirect(
                URL(string: "https://evil.example/omview/OMLVU28480_19/toc.html")!,
                from: frame,
                immediateResponse: frameHTTPS
            )
        )
    }

    func testPageRequestOmitsCredentialsAndCookies() {
        let request = URLManualFetcher.makePageRequest(for: suppliedURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, suppliedURL)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "PropertyManagerApp/1.0 (local manufacturer manual import)"
        )
        XCTAssertNil(URLManualFetcher.pageSession.configuration.urlCredentialStorage)
        XCTAssertNil(URLManualFetcher.pageSession.configuration.httpCookieStorage)
    }

    func testPackagedInfoPlistAllowsOnlyExactDeereHTTP() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let root = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ats = try XCTUnwrap(root["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertNil(ats["NSAllowsArbitraryLoads"])
        XCTAssertNil(ats["NSAllowsArbitraryLoadsInWebContent"])
        XCTAssertNil(ats["NSAllowsArbitraryLoadsForMedia"])
        let domains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: Any])
        XCTAssertEqual(Set(domains.keys), ["manuals.deere.com"])
        let deere = try XCTUnwrap(domains["manuals.deere.com"] as? [String: Any])
        XCTAssertEqual(deere["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
        XCTAssertEqual(deere["NSIncludesSubdomains"] as? Bool, false)
        XCTAssertNil(deere["NSExceptionMinimumTLSVersion"])
        XCTAssertNil(deere["NSExceptionRequiresForwardSecrecy"])
    }
}
