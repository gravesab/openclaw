import XCTest

private struct RanchFileProbe: Decodable {
    let id: UUID
    let name: String
}

private struct RanchApplicationsProbe: Decodable {
    struct Application: Decodable {
        let name: String
        let dataName: String
    }

    let applications: [Application]
}

/// Opened-as slice: the page is opened as the administrator or as one saved
/// person. Only the administrator and owners change who has access; a manager
/// or viewer is refused and nothing is written. The opened-as choice is never
/// written to the file. Each test uses its own temporary file. Nothing
/// reaches the network.
final class RanchOSPeopleStoreTests: XCTestCase {
    func testStoreStartsAsAdministrator() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await RanchOSPeopleStore(fileURL: url)

        let line = await store.openedAsLine
        let options = await store.openedAsOptions
        XCTAssertNil(line)
        XCTAssertTrue(options.isEmpty)

        await store.addRanch(name: "Andrew Graves Ranch")
        let added = await store.ranchSections
        let ranchID = try XCTUnwrap(added.first?.id)
        await store.assign(name: "Andrew Graves", email: "andrew@ranchos.dev", role: .owner, ranchID: ranchID)

        let sections = await store.ranchSections
        let message = await store.message
        XCTAssertEqual(sections.first?.people.count, 1)
        XCTAssertNil(message)
    }

    func testOpenedAsManagerRefusesAllMutations() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (store, ranchID, andrewID, royID) = try await makeStoreWithAndrewAndRoy(fileURL: url)

        await store.setOpenedAs(id: royID)
        let line = await store.openedAsLine
        XCTAssertEqual(line, "Opened as Roy Graves · Manager · Andrew Graves Ranch.")
        let before = try Data(contentsOf: url)

        await store.addRanch(name: "North Pasture")
        let addMessage = await store.message
        await store.assign(name: "Sam", email: "sam@ranchos.dev", role: .viewer, ranchID: ranchID)
        let assignMessage = await store.message
        await store.changeRole(id: royID, role: .viewer)
        let roleMessage = await store.message
        await store.revoke(id: andrewID)
        let revokeMessage = await store.message

        XCTAssertEqual(addMessage, "The administrator adds a ranch.")
        XCTAssertEqual(assignMessage, "An owner changes who has access.")
        XCTAssertEqual(roleMessage, "An owner changes who has access.")
        XCTAssertEqual(revokeMessage, "An owner changes who has access.")
        let after = try Data(contentsOf: url)
        XCTAssertEqual(after, before)
    }

    func testOpenedAsOwnerSaves() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (store, ranchID, andrewID, _) = try await makeStoreWithAndrewAndRoy(fileURL: url)

        await store.setOpenedAs(id: andrewID)
        await store.assign(name: "Sam", email: "sam@ranchos.dev", role: .viewer, ranchID: ranchID)

        let sections = await store.ranchSections
        let message = await store.message
        XCTAssertEqual(sections.first?.people.count, 3)
        XCTAssertNil(message)
        let reloaded = await RanchOSPeopleStore(fileURL: url)
        let again = await reloaded.ranchSections
        XCTAssertEqual(again.first?.people.count, 3)
    }

    func testRemovingOpenedAsPersonReturnsToAdministrator() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (store, _, andrewID, _) = try await makeStoreWithAndrewAndRoy(fileURL: url)

        await store.setOpenedAs(id: andrewID)
        let before = await store.openedAsLine
        XCTAssertEqual(before, "Opened as Andrew Graves · Owner · Andrew Graves Ranch.")

        await store.revoke(id: andrewID)

        let line = await store.openedAsLine
        XCTAssertNil(line)
        await store.addRanch(name: "North Pasture")
        let sections = await store.ranchSections
        XCTAssertEqual(sections.count, 2)
    }

    func testReloadIsAdministratorWithPeople() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (store, _, _, royID) = try await makeStoreWithAndrewAndRoy(fileURL: url)
        await store.setOpenedAs(id: royID)

        let reloaded = await RanchOSPeopleStore(fileURL: url)

        let line = await reloaded.openedAsLine
        let sections = await reloaded.ranchSections
        XCTAssertNil(line)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.people.count, 2)
    }

    func testAddRanchSavesEmptyWithSaved() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await RanchOSPeopleStore(fileURL: url)

        await store.addRanch(name: "Andrew Graves Ranch")

        let sections = await store.ranchSections
        let ranch = try XCTUnwrap(sections.first)
        let message = await store.message
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(ranch.name, "Andrew Graves Ranch")
        XCTAssertTrue(ranch.people.isEmpty)
        XCTAssertTrue(ranch.saved)
        XCTAssertNil(message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDuplicateRanchRefused() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")

        await store.addRanch(name: "andrew graves ranch")
        let afterCase = await store.ranchSections
        let caseMessage = await store.message
        await store.addRanch(name: "  Andrew Graves Ranch ")
        let afterSpaces = await store.ranchSections
        let spacesMessage = await store.message

        XCTAssertEqual(afterCase.count, 1)
        XCTAssertEqual(caseMessage, "A ranch with that name already exists.")
        XCTAssertEqual(afterSpaces.count, 1)
        XCTAssertEqual(spacesMessage, "A ranch with that name already exists.")
    }

    func testBlankRanchRefused() async {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await RanchOSPeopleStore(fileURL: url)

        await store.addRanch(name: "")
        let afterEmpty = await store.ranchSections
        let emptyMessage = await store.message
        await store.addRanch(name: "   ")
        let afterSpaces = await store.ranchSections
        let spacesMessage = await store.message

        XCTAssertTrue(afterEmpty.isEmpty)
        XCTAssertEqual(emptyMessage, "Give the ranch a name before adding it.")
        XCTAssertTrue(afterSpaces.isEmpty)
        XCTAssertEqual(spacesMessage, "Give the ranch a name before adding it.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAssignWithNoRanchNamesRefused() async {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await RanchOSPeopleStore(fileURL: url)

        await store.assign(name: "Sam", email: "sam@ranchos.dev", role: .viewer, ranchID: nil)

        let sections = await store.ranchSections
        let message = await store.message
        XCTAssertTrue(sections.isEmpty)
        XCTAssertEqual(message, "Add a ranch name first.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testChangeRoleUpdatesSavedFile() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "North Pasture")
        let added = await store.ranchSections
        let ranchID = try XCTUnwrap(added.first?.id)
        await store.assign(name: "Sam", email: "sam@ranchos.dev", role: .viewer, ranchID: ranchID)
        let before = await store.ranchSections
        let sam = try XCTUnwrap(before.first?.people.first)

        await store.changeRole(id: sam.id, role: .manager)

        let reloaded = await RanchOSPeopleStore(fileURL: url)
        let after = await reloaded.ranchSections
        let person = try XCTUnwrap(after.first?.people.first)
        let message = await store.message
        XCTAssertEqual(person.role, .manager)
        XCTAssertNil(message)
    }

    func testRevokeUpdatesSavedFile() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let (store, _, _, royID) = try await makeStoreWithAndrewAndRoy(fileURL: url)

        await store.revoke(id: royID)

        let reloaded = await RanchOSPeopleStore(fileURL: url)
        let after = await reloaded.ranchSections
        let ranch = try XCTUnwrap(after.first)
        XCTAssertEqual(ranch.people.count, 1)
        XCTAssertEqual(ranch.people.first?.name, "Andrew Graves")
    }

    func testCorruptFileStartsEmpty() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        let store = await RanchOSPeopleStore(fileURL: url)

        let sections = await store.ranchSections
        let message = await store.message
        XCTAssertTrue(sections.isEmpty)
        XCTAssertEqual(message, "Saved people couldn't be read. Starting empty.")
    }

    func testAddRanchWritesRanchFileWithMatchingID() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)

        await store.addRanch(name: "Andrew Graves Ranch")

        let sections = await store.ranchSections
        let ranch = try XCTUnwrap(sections.first)
        XCTAssertTrue(ranch.hasOwnData)
        let fileURL = ranchFileURL(dir: dir, id: ranch.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let data = try Data(contentsOf: fileURL)
        let file = try JSONDecoder().decode(RanchFileProbe.self, from: data)
        XCTAssertEqual(file.id, ranch.id)
        XCTAssertEqual(file.name, "Andrew Graves Ranch")
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let idRange = try XCTUnwrap(raw.range(of: "\"id\""))
        let nameRange = try XCTUnwrap(raw.range(of: "\"name\" : \"Andrew Graves Ranch\""))
        XCTAssertTrue(idRange.lowerBound < nameRange.lowerBound)
    }

    func testSecondRanchLeavesFirstFileBytesUnchanged() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        let firstSections = await store.ranchSections
        let first = try XCTUnwrap(firstSections.first)
        let firstBytes = try Data(contentsOf: ranchFileURL(dir: dir, id: first.id))

        await store.addRanch(name: "North Pasture")

        let sections = await store.ranchSections
        XCTAssertEqual(sections.count, 2)
        XCTAssertTrue(sections.allSatisfy(\.hasOwnData))
        let second = try XCTUnwrap(sections.first(where: { $0.name == "North Pasture" }))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ranchFileURL(dir: dir, id: second.id).path))
        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: first.id)), firstBytes)
    }

    func testBlankNameWritesNoRanchFile() async {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)

        await store.addRanch(name: "   ")

        XCTAssertFalse(FileManager.default.fileExists(atPath: ranchesDirectory(dir: dir).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDuplicateNameWritesNoRanchFile() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        let firstSections = await store.ranchSections
        let first = try XCTUnwrap(firstSections.first)
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: ranchesDirectory(dir: dir).path)
        let beforeBytes = try Data(contentsOf: ranchFileURL(dir: dir, id: first.id))

        await store.addRanch(name: "andrew graves ranch")

        let sections = await store.ranchSections
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ranchesDirectory(dir: dir).path), beforeFiles)
        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: first.id)), beforeBytes)
    }

    func testManagerAddWritesNoRanchFile() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let (store, _, _, royID) = try await makeStoreWithAndrewAndRoy(fileURL: url)
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: ranchesDirectory(dir: dir).path)

        await store.setOpenedAs(id: royID)
        await store.addRanch(name: "North Pasture")

        let message = await store.message
        XCTAssertEqual(message, "The administrator adds a ranch.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ranchesDirectory(dir: dir).path), beforeFiles)
    }

    func testOpenedRanchShowsOnlyThatRanch() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        await store.addRanch(name: "North Pasture")
        let both = await store.ranchSections
        XCTAssertEqual(both.map(\.name), ["Andrew Graves Ranch", "North Pasture"])
        let firstID = try XCTUnwrap(both.first?.id)
        let secondID = try XCTUnwrap(both.dropFirst().first?.id)
        await store.assign(name: "Andrew Graves", email: "andrew@ranchos.dev", role: .owner, ranchID: firstID)
        let assigned = await store.ranchSections
        let andrewID = try XCTUnwrap(assigned.first?.people.first?.id)

        await store.setOpenedAs(id: andrewID)
        let opened = await store.ranchSections
        XCTAssertEqual(opened.map(\.id), [firstID])
        let options = await store.openedAsOptions
        XCTAssertEqual(options.count, 1)

        await store.assign(name: "Sam", email: "sam@ranchos.dev", role: .viewer, ranchID: firstID)
        let assignMessage = await store.message
        let afterAssign = await store.ranchSections
        XCTAssertNil(assignMessage)
        XCTAssertEqual(afterAssign.first?.people.count, 2)

        let peopleBefore = try Data(contentsOf: url)
        let firstFile = try Data(contentsOf: ranchFileURL(dir: dir, id: firstID))
        let secondFile = try Data(contentsOf: ranchFileURL(dir: dir, id: secondID))
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: ranchesDirectory(dir: dir).path)

        await store.addRanch(name: "South Pasture")
        let addMessage = await store.message
        XCTAssertEqual(addMessage, "The administrator adds a ranch.")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: ranchesDirectory(dir: dir).path),
            filesBefore)

        await store.assign(name: "Pat", email: "pat@ranchos.dev", role: .viewer, ranchID: secondID)
        let crossMessage = await store.message
        XCTAssertEqual(crossMessage, "An owner changes who has access.")
        XCTAssertEqual(try Data(contentsOf: url), peopleBefore)
        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: firstID)), firstFile)
        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: secondID)), secondFile)

        await store.setOpenedAs(id: nil)
        let adminAgain = await store.ranchSections
        XCTAssertEqual(adminAgain.map(\.name), ["Andrew Graves Ranch", "North Pasture"])

        let reloaded = await RanchOSPeopleStore(fileURL: url)
        let reloadedLine = await reloaded.openedAsLine
        let reloadedSections = await reloaded.ranchSections
        XCTAssertNil(reloadedLine)
        XCTAssertEqual(reloadedSections.map(\.name), ["Andrew Graves Ranch", "North Pasture"])
    }

    func testReloadBackfillsMissingRanchFile() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        let added = await store.ranchSections
        let ranchID = try XCTUnwrap(added.first?.id)
        await store.assign(name: "Andrew Graves", email: "andrew@ranchos.dev", role: .owner, ranchID: ranchID)
        try FileManager.default.removeItem(at: ranchFileURL(dir: dir, id: ranchID))
        let peopleBytes = try Data(contentsOf: url)

        let reloaded = await RanchOSPeopleStore(fileURL: url)

        let sections = await reloaded.ranchSections
        let ranch = try XCTUnwrap(sections.first)
        XCTAssertTrue(ranch.hasOwnData)
        XCTAssertEqual(ranch.people.count, 1)
        let file = try JSONDecoder().decode(
            RanchFileProbe.self, from: Data(contentsOf: ranchFileURL(dir: dir, id: ranchID)))
        XCTAssertEqual(file.id, ranchID)
        XCTAssertEqual(file.name, "Andrew Graves Ranch")
        XCTAssertEqual(try Data(contentsOf: url), peopleBytes)
    }

    func testRefusedChangeAfterBackfillChangesNothing() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        let added = await store.ranchSections
        let ranchID = try XCTUnwrap(added.first?.id)
        try FileManager.default.removeItem(at: ranchFileURL(dir: dir, id: ranchID))
        let reloaded = await RanchOSPeopleStore(fileURL: url)
        let peopleBytes = try Data(contentsOf: url)
        let ranchBytes = try Data(contentsOf: ranchFileURL(dir: dir, id: ranchID))

        await reloaded.addRanch(name: "Andrew Graves Ranch")

        let message = await reloaded.message
        XCTAssertEqual(message, "A ranch with that name already exists.")
        XCTAssertEqual(try Data(contentsOf: url), peopleBytes)
        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: ranchID)), ranchBytes)
    }

    func testCorruptFileWritesNoRanchFile() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        let store = await RanchOSPeopleStore(fileURL: url)

        let message = await store.message
        XCTAssertEqual(message, "Saved people couldn't be read. Starting empty.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ranchesDirectory(dir: dir).path))
    }

    func testAssignRoleRevokeDoNotRewriteRanchFiles() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let (store, ranchID, _, royID) = try await makeStoreWithAndrewAndRoy(fileURL: url)
        let beforeBytes = try Data(contentsOf: ranchFileURL(dir: dir, id: ranchID))

        await store.assign(name: "Sam", email: "sam@ranchos.dev", role: .viewer, ranchID: ranchID)
        await store.changeRole(id: royID, role: .viewer)
        let samSections = await store.ranchSections
        let sam = try XCTUnwrap(samSections.first?.people.first(where: { $0.name == "Sam" }))
        await store.revoke(id: sam.id)

        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: ranchID)), beforeBytes)
    }

    func testRanchFileStoresFourDistinctApplicationNames() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        let firstSections = await store.ranchSections
        let first = try XCTUnwrap(firstSections.first)
        let firstBytes = try Data(contentsOf: ranchFileURL(dir: dir, id: first.id))
        let firstNames = try applicationDataNames(dir: dir, id: first.id)
        XCTAssertEqual(firstNames.map(\.name), ["People", "Livestock", "Finance", "Property Manager"])
        XCTAssertEqual(Set(firstNames.map(\.dataName)).count, 4)
        let key = first.id.uuidString.lowercased()
        XCTAssertEqual(firstNames.map(\.dataName), [
            "people-\(key)", "livestock-\(key)", "finance-\(key)", "property-manager-\(key)",
        ])
        XCTAssertEqual(first.applications.map(\.name), firstNames.map(\.name))

        await store.addRanch(name: "North Pasture")
        let secondSections = await store.ranchSections
        let second = try XCTUnwrap(secondSections.first(where: { $0.name == "North Pasture" }))
        let secondNames = try applicationDataNames(dir: dir, id: second.id)
        XCTAssertTrue(Set(firstNames.map(\.dataName)).isDisjoint(with: secondNames.map(\.dataName)))
        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: first.id)), firstBytes)
    }

    func testOlderRanchFileGainsApplicationNames() async throws {
        let dir = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("people.json")
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        let added = await store.ranchSections
        let ranchID = try XCTUnwrap(added.first?.id)
        let peopleBytes = try Data(contentsOf: url)
        let bare = """
        {
          "id" : "\(ranchID.uuidString)",
          "name" : "Andrew Graves Ranch"
        }
        """
        try bare.write(to: ranchFileURL(dir: dir, id: ranchID), atomically: true, encoding: .utf8)

        let reloaded = await RanchOSPeopleStore(fileURL: url)
        XCTAssertEqual(try Data(contentsOf: url), peopleBytes)
        let names = try applicationDataNames(dir: dir, id: ranchID)
        XCTAssertEqual(names.map(\.name), ["People", "Livestock", "Finance", "Property Manager"])
        let reloadedSections = await reloaded.ranchSections
        let section = try XCTUnwrap(reloadedSections.first)
        XCTAssertEqual(section.applications.map(\.dataName), names.map(\.dataName))
        let ranchBytes = try Data(contentsOf: ranchFileURL(dir: dir, id: ranchID))

        _ = await RanchOSPeopleStore(fileURL: url)
        XCTAssertEqual(try Data(contentsOf: url), peopleBytes)
        XCTAssertEqual(try Data(contentsOf: ranchFileURL(dir: dir, id: ranchID)), ranchBytes)
    }

    // MARK: - Helpers

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func ranchesDirectory(dir: URL) -> URL {
        dir.appendingPathComponent("ranches", isDirectory: true)
    }

    private func ranchFileURL(dir: URL, id: UUID) -> URL {
        ranchesDirectory(dir: dir).appendingPathComponent(id.uuidString + ".json")
    }

    private func applicationDataNames(dir: URL, id: UUID) throws -> [RanchApplicationsProbe.Application] {
        let file = try JSONDecoder().decode(
            RanchApplicationsProbe.self, from: Data(contentsOf: ranchFileURL(dir: dir, id: id)))
        return file.applications
    }

    private func makeStoreWithAndrewAndRoy(fileURL url: URL) async throws -> (RanchOSPeopleStore, UUID, UUID, UUID) {
        let store = await RanchOSPeopleStore(fileURL: url)
        await store.addRanch(name: "Andrew Graves Ranch")
        let added = await store.ranchSections
        let ranchID = try XCTUnwrap(added.first?.id)
        await store.assign(name: "Andrew Graves", email: "andrew@ranchos.dev", role: .owner, ranchID: ranchID)
        await store.assign(name: "Roy Graves", email: "roy@ranchos.dev", role: .manager, ranchID: ranchID)
        let after = await store.ranchSections
        let people = try XCTUnwrap(after.first?.people)
        let andrew = try XCTUnwrap(people.first(where: { $0.name == "Andrew Graves" }))
        let roy = try XCTUnwrap(people.first(where: { $0.name == "Roy Graves" }))
        return (store, ranchID, andrew.id, roy.id)
    }
}
