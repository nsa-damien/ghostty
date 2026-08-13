import XCTest
@testable import Ghostty

final class ProjectSidebarWorkspaceModelTests: XCTestCase {
    func testValidatorEnforcesScopedNamesAndStableMetadata() throws {
        let entry = ProjectSidebarTerminal(name: " Terminal ", launchDirectory: "/tmp")
        let project = ProjectSidebarProject(
            name: "Project",
            baseFolder: "/tmp",
            groups: [ProjectSidebarGroup(name: "Group", entries: [entry])]
        )

        XCTAssertNoThrow(try ProjectSidebarWorkspace(projects: [project]).validated())
        XCTAssertEqual(ProjectSidebarWorkspaceValidator.normalizedName("  TERMINAL "), "terminal")
        XCTAssertEqual(project.allEntries.first?.launchDirectory, "/tmp")
    }

    func testValidatorRejectsDuplicateProjectFoldersAndSiblingNames() {
        let one = ProjectSidebarProject(name: "One", baseFolder: "/tmp")
        let two = ProjectSidebarProject(name: "Two", baseFolder: "/tmp/.")
        XCTAssertThrowsError(try ProjectSidebarWorkspace(projects: [one, two]).validated()) { error in
            XCTAssertEqual(error as? ProjectSidebarValidationError, .duplicateBaseFolder)
        }

        let a = ProjectSidebarTerminal(name: "Shell", launchDirectory: "/tmp")
        let b = ProjectSidebarTerminal(name: " shell ", launchDirectory: "/tmp")
        let project = ProjectSidebarProject(name: "Project", baseFolder: "/tmp", ungroupedEntries: [a, b])
        XCTAssertThrowsError(try ProjectSidebarWorkspace(projects: [project]).validated()) { error in
            XCTAssertEqual(error as? ProjectSidebarValidationError, .duplicateName)
        }
    }

    func testStoreRoundTripsAndKeepsProcessFreeState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectSidebarStore(directoryURL: directory)
        let workspace = ProjectSidebarWorkspace(
            projects: [ProjectSidebarProject(name: "Ghostty", baseFolder: "/tmp")],
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
        let first = ProjectSidebarWorkspace(projects: [ProjectSidebarProject(name: "First", baseFolder: "/tmp")])
        let second = ProjectSidebarWorkspace(projects: [ProjectSidebarProject(name: "Second", baseFolder: "/tmp")])
        try store.save(first)
        try store.save(second)
        try Data("not-json".utf8).write(to: store.primaryURL)

        let result = store.load()
        XCTAssertTrue(result.recoveredFromBackup)
        XCTAssertEqual(result.workspace, first)
        XCTAssertNotNil(result.notice)
    }
}
