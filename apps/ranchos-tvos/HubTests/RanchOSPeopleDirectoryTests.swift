import XCTest

final class RanchOSPeopleDirectoryTests: XCTestCase {
    func testDevelopmentOwnerSeedsOneOwner() {
        let directory = RanchOSPeopleDirectory.developmentOwner()

        XCTAssertEqual(directory.people.count, 1)
        XCTAssertEqual(directory.people.first?.name, "Ranch owner")
        XCTAssertEqual(directory.people.first?.email, "owner@ranchos.dev")
        XCTAssertEqual(directory.people.first?.role, .owner)
        XCTAssertTrue(directory.canManage)
    }

    func testOwnerInviteAddsOneActivePerson() throws {
        let directory = RanchOSPeopleDirectory.developmentOwner()

        let person = try directory.invite(name: "Sam Rivera", email: "Sam@Ranchos.dev", role: .manager)

        XCTAssertEqual(directory.people.count, 2)
        XCTAssertEqual(person.name, "Sam Rivera")
        XCTAssertEqual(person.email, "sam@ranchos.dev")
        XCTAssertEqual(person.role, .manager)
    }

    func testManagerAndViewerCannotInviteChangeRoleOrRevoke() throws {
        for role in [RanchOSPersonRole.manager, .viewer] {
            let directory = RanchOSPeopleDirectory.developmentOwner()
            let ownerID = try XCTUnwrap(directory.people.first?.id)
            directory.actorRole = role

            XCTAssertThrowsError(try directory.invite(name: "Sam", email: "sam@ranchos.dev", role: .viewer)) { error in
                XCTAssertEqual(error as? RanchOSPeopleError, .notAllowed)
            }
            XCTAssertThrowsError(try directory.changeRole(id: ownerID, role: .viewer)) { error in
                XCTAssertEqual(error as? RanchOSPeopleError, .notAllowed)
            }
            XCTAssertThrowsError(try directory.revoke(id: ownerID)) { error in
                XCTAssertEqual(error as? RanchOSPeopleError, .notAllowed)
            }
            XCTAssertEqual(directory.people.count, 1)
        }
    }

    func testDuplicateEmailFailsClosedCaseInsensitively() throws {
        let directory = RanchOSPeopleDirectory.developmentOwner()
        try directory.invite(name: "Sam", email: "sam@ranchos.dev", role: .viewer)

        XCTAssertThrowsError(try directory.invite(name: "Other Sam", email: "SAM@ranchos.dev", role: .viewer)) { error in
            XCTAssertEqual(error as? RanchOSPeopleError, .duplicateEmail)
        }
        XCTAssertEqual(directory.people.count, 2)
    }

    func testInvalidNameFailsClosed() {
        let directory = RanchOSPeopleDirectory.developmentOwner()

        for name in ["", "   "] {
            XCTAssertThrowsError(try directory.invite(name: name, email: "sam@ranchos.dev", role: .viewer)) { error in
                XCTAssertEqual(error as? RanchOSPeopleError, .invalidName)
            }
        }
        XCTAssertTrue(directory.people.count == 1)
    }

    func testInvalidEmailFailsClosed() {
        let directory = RanchOSPeopleDirectory.developmentOwner()

        for email in ["sam", "sam@", "@ranchos.dev", "sam@ranchos", "  "] {
            XCTAssertThrowsError(try directory.invite(name: "Sam", email: email, role: .viewer)) { error in
                XCTAssertEqual(error as? RanchOSPeopleError, .invalidEmail, "email: \(email)")
            }
        }
        XCTAssertEqual(directory.people.count, 1)
    }

    func testRevokeRemovesPersonFromList() throws {
        let directory = RanchOSPeopleDirectory.developmentOwner()
        let person = try directory.invite(name: "Sam", email: "sam@ranchos.dev", role: .manager)

        try directory.revoke(id: person.id)

        XCTAssertTrue(directory.people.allSatisfy { $0.id != person.id })
        XCTAssertThrowsError(try directory.revoke(id: person.id)) { error in
            XCTAssertEqual(error as? RanchOSPeopleError, .unknownPerson)
        }
    }

    func testSoleOwnerCannotBeRevokedOrDemoted() throws {
        let directory = RanchOSPeopleDirectory.developmentOwner()
        let ownerID = try XCTUnwrap(directory.people.first?.id)

        XCTAssertThrowsError(try directory.revoke(id: ownerID)) { error in
            XCTAssertEqual(error as? RanchOSPeopleError, .lastOwner)
        }
        XCTAssertThrowsError(try directory.changeRole(id: ownerID, role: .manager)) { error in
            XCTAssertEqual(error as? RanchOSPeopleError, .lastOwner)
        }
        XCTAssertEqual(directory.people.count, 1)
        XCTAssertEqual(directory.people.first?.role, .owner)
    }

    func testEitherOfTwoOwnersMayBeDemotedOrRemoved() throws {
        let directory = RanchOSPeopleDirectory.developmentOwner()
        let firstOwnerID = try XCTUnwrap(directory.people.first?.id)
        let second = try directory.invite(name: "Jo", email: "jo@ranchos.dev", role: .owner)

        try directory.changeRole(id: second.id, role: .manager)
        XCTAssertEqual(directory.people.first(where: { $0.id == second.id })?.role, .manager)

        try directory.changeRole(id: second.id, role: .owner)
        try directory.revoke(id: firstOwnerID)
        XCTAssertEqual(directory.people.map(\.id), [second.id])
        XCTAssertEqual(directory.people.first?.role, .owner)
    }

    func testUnknownPersonFailsClosed() {
        let directory = RanchOSPeopleDirectory.developmentOwner()

        XCTAssertThrowsError(try directory.changeRole(id: UUID(), role: .viewer)) { error in
            XCTAssertEqual(error as? RanchOSPeopleError, .unknownPerson)
        }
        XCTAssertThrowsError(try directory.revoke(id: UUID())) { error in
            XCTAssertEqual(error as? RanchOSPeopleError, .unknownPerson)
        }
    }
}
