import XCTest
@testable import Ghostty

final class ProjectSidebarWorkspaceModelTests: XCTestCase {
    func testValidatorEnforcesScopedNamesAndStableMetadata() throws {
        let entry = ProjectSidebarTerminal(name: " Terminal ", launchDirectory: "/tmp")
        let project = ProjectSidebarProject(
            name: "Project",
            baseFolder: "/tmp",
            terminals: [entry]
        )
        let group = ProjectSidebarGroup(name: "Clients", projects: [project])

        XCTAssertNoThrow(try ProjectSidebarWorkspace(groups: [group]).validated())
        XCTAssertEqual(ProjectSidebarWorkspaceValidator.normalizedName("  TERMINAL "), "terminal")
        XCTAssertEqual(project.terminals.first?.launchDirectory, "/tmp")
    }

    func testValidatorRejectsDuplicateProjectFoldersAndSiblingNames() {
        let one = ProjectSidebarProject(name: "One", baseFolder: "/tmp")
        let two = ProjectSidebarProject(name: "Two", baseFolder: "/tmp/.")
        XCTAssertThrowsError(try ProjectSidebarWorkspace(ungroupedProjects: [one, two]).validated()) { error in
            XCTAssertEqual(error as? ProjectSidebarValidationError, .duplicateBaseFolder)
        }

        let a = ProjectSidebarTerminal(name: "Shell", launchDirectory: "/tmp")
        let b = ProjectSidebarTerminal(name: " shell ", launchDirectory: "/tmp")
        let project = ProjectSidebarProject(name: "Project", baseFolder: "/tmp", terminals: [a, b])
        XCTAssertThrowsError(try ProjectSidebarWorkspace(ungroupedProjects: [project]).validated()) { error in
            XCTAssertEqual(error as? ProjectSidebarValidationError, .duplicateName)
        }
    }

    func testStoreRoundTripsAndKeepsProcessFreeState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectSidebarStore(directoryURL: directory)
        let workspace = ProjectSidebarWorkspace(
            ungroupedProjects: [ProjectSidebarProject(name: "Ghostty", baseFolder: "/tmp")],
            sidebarVisible: false,
            sidebarWidth: 300
        )

        try store.save(workspace)
        XCTAssertEqual(store.load().workspace, workspace)

        let data = try Data(contentsOf: store.primaryURL)
        let text = String(bytes: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("running"))
        XCTAssertFalse(text.contains("surface"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.primaryURL.path))
    }

    func testStoreRecoversFromBackupAfterPrimaryCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectSidebarStore(directoryURL: directory)
        let first = ProjectSidebarWorkspace(ungroupedProjects: [ProjectSidebarProject(name: "First", baseFolder: "/tmp")])
        let second = ProjectSidebarWorkspace(ungroupedProjects: [ProjectSidebarProject(name: "Second", baseFolder: "/tmp")])
        try store.save(first)
        try store.save(second)
        try Data("not-json".utf8).write(to: store.primaryURL)

        let result = store.load()
        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.workspace, first)
        XCTAssertNotNil(result.notice)
    }

    func testStorePreservesAndReportsNewerWorkspaceVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectSidebarStore(directoryURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("{\"version\":999,\"workspace\":{}}".utf8)
        try data.write(to: store.primaryURL)

        let result = store.load()

        XCTAssertEqual(result.workspace, .empty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.primaryURL.path))
        XCTAssertTrue(result.notice?.contains("newer") == true)
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), data)
    }

    func testVersionOneWorkspaceMigratesProjectsAndFlattensTerminalGroupsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectSidebarStore(directoryURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let legacyGroupID = UUID()
        let json = """
        {
          "version": 1,
          "workspace": {
            "projects": [{
              "id": "\(projectID.uuidString)",
              "name": "Legacy",
              "baseFolder": "/tmp",
              "isExpanded": true,
              "ungroupedEntries": [{
                "id": "\(firstID.uuidString)",
                "name": "Terminal 1",
                "launchDirectory": "/tmp"
              }],
              "groups": [{
                "id": "\(legacyGroupID.uuidString)",
                "name": "Old Terminal Group",
                "isExpanded": true,
                "entries": [{
                  "id": "\(secondID.uuidString)",
                  "name": "Terminal 2",
                  "launchDirectory": "/tmp"
                }]
              }]
            }],
            "sidebarVisible": true,
            "sidebarWidth": 240
          }
        }
        """
        try Data(json.utf8).write(to: store.primaryURL)

        let result = store.load()

        XCTAssertNil(result.notice)
        XCTAssertTrue(result.workspace.groups.isEmpty)
        XCTAssertEqual(result.workspace.ungroupedProjects.map(\.id), [projectID])
        XCTAssertEqual(result.workspace.ungroupedProjects[0].terminals.map(\.id), [firstID, secondID])
        XCTAssertEqual(Set(result.workspace.ungroupedProjects[0].terminals.map(\.id)).count, 2)
    }

    func testValidatorRejectsDuplicateProjectsAcrossTopLevelGroups() {
        let project = ProjectSidebarProject(name: "Relay", baseFolder: "/tmp")
        let grouped = ProjectSidebarGroup(name: "Control Room", projects: [project])
        let workspace = ProjectSidebarWorkspace(groups: [grouped], ungroupedProjects: [project])

        XCTAssertThrowsError(try workspace.validated()) { error in
            XCTAssertEqual(error as? ProjectSidebarValidationError, .duplicateIdentifier)
        }
    }

    func testProjectsCanReorderWithinFolderAndMoveBetweenFolders() {
        let relay = ProjectSidebarProject(name: "Relay", baseFolder: "/tmp/relay")
        let exodus = ProjectSidebarProject(name: "Exodus", baseFolder: "/tmp/exodus")
        let dataWrangler = ProjectSidebarProject(name: "Data Wrangler", baseFolder: "/tmp/data-wrangler")
        let controlRoomID = UUID()
        let archiveID = UUID()
        var workspace = ProjectSidebarWorkspace(groups: [
            ProjectSidebarGroup(
                id: controlRoomID,
                name: "Control Room",
                projects: [relay, exodus, dataWrangler]
            ),
            ProjectSidebarGroup(id: archiveID, name: "Archive"),
        ])

        XCTAssertTrue(workspace.moveProject(dataWrangler.id, toGroup: controlRoomID, before: relay.id))
        XCTAssertEqual(workspace.groups[0].projects.map(\.id), [dataWrangler.id, relay.id, exodus.id])

        XCTAssertTrue(workspace.moveProject(exodus.id, toGroup: archiveID, before: nil))
        XCTAssertEqual(workspace.groups[0].projects.map(\.id), [dataWrangler.id, relay.id])
        XCTAssertEqual(workspace.groups[1].projects.map(\.id), [exodus.id])
    }

    func testFoldersCanReorder() {
        let controlRoom = ProjectSidebarGroup(name: "Control Room")
        let clientWork = ProjectSidebarGroup(name: "Client Work")
        let archive = ProjectSidebarGroup(name: "Archive")
        var workspace = ProjectSidebarWorkspace(groups: [controlRoom, clientWork, archive])

        XCTAssertTrue(workspace.moveGroup(archive.id, before: controlRoom.id))
        XCTAssertEqual(workspace.groups.map(\.id), [archive.id, controlRoom.id, clientWork.id])

        XCTAssertTrue(workspace.moveGroup(archive.id, before: nil))
        XCTAssertEqual(workspace.groups.map(\.id), [controlRoom.id, clientWork.id, archive.id])
    }
}
