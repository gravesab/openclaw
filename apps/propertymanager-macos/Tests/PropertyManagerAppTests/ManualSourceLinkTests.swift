import XCTest
@testable import PropertyManagerApp

final class ManualSourceLinkTests: XCTestCase {
    func testSavedLegacyTaskUsesActualProcedureURLMatchingSourceHost() {
        let actual = "http://manuals.deere.com/omview/OMLVU28480_19/KN52281,1003F0D_19_20120822.html"
        XCTAssertEqual(ManualSourceLink.url(
            provenanceURL: nil,
            displayName: "manuals.deere.com/OMLVU28480_19/toc.html — Operator's Manual",
            instructions: "Follow the manufacturer procedure at \(actual)."
        )?.absoluteString, actual)
        XCTAssertNil(ManualSourceLink.url(
            provenanceURL: nil, displayName: "manuals.deere.com/shortened",
            instructions: "Buy parts at https://example.com/parts."
        ))
    }

    func testUsesOriginalURLInsteadOfShortenedImportedLabel() {
        let original = "http://manuals.deere.com/omview/OMLVU28480_19/?tM="
        XCTAssertEqual(ManualSourceLink.url(
            provenanceURL: original,
            displayName: "manuals.deere.com/OMLVU28480_19/toc.html — Operator's Manual"
        )?.absoluteString, original)
    }

    func testExplicitURLWorksWithoutImportProvenance() {
        XCTAssertEqual(ManualSourceLink.url(
            provenanceURL: nil, displayName: " https://example.com/manual.pdf "
        )?.absoluteString, "https://example.com/manual.pdf")
    }

    func testDoesNotInventLinksFromPDFNamesOrShortenedLabels() {
        for label in ["Operator Manual.pdf", "manuals.deere.com/OMLVU28480_19/toc.html"] {
            XCTAssertNil(ManualSourceLink.url(provenanceURL: nil, displayName: label))
        }
    }

    func testRejectsNonWebAndCredentialURLs() {
        for value in ["file:///tmp/manual.pdf", "javascript:alert(1)", "https://user:pass@example.com/manual", "https://", "https://example.com/manual — Title"] {
            XCTAssertNil(ManualSourceLink.url(provenanceURL: value, displayName: value))
        }
    }
}
