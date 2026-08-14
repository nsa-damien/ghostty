import Combine
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

    func testAppendingProjectExpandsCollapsedTargetFolder() {
        let group = ProjectSidebarGroup(name: "Collapsed", isExpanded: false)
        let project = ProjectSidebarProject(name: "Ghostty", baseFolder: "/tmp")
        var workspace = ProjectSidebarWorkspace(groups: [group])

        XCTAssertTrue(workspace.appendProject(project, toGroup: group.id))

        XCTAssertEqual(workspace.groups[0].projects, [project])
        XCTAssertTrue(workspace.groups[0].isExpanded)
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

    func testDropPlannerMovesUngroupedProjectIntoFolder() {
        let relay = ProjectSidebarProject(name: "Relay", baseFolder: "/tmp/relay")
        let exodus = ProjectSidebarProject(name: "Exodus", baseFolder: "/tmp/exodus")
        let controlRoom = ProjectSidebarGroup(name: "Control Room", projects: [relay])
        let workspace = ProjectSidebarWorkspace(
            groups: [controlRoom],
            ungroupedProjects: [exodus]
        )

        XCTAssertEqual(
            ProjectSidebarDropPlanner.plan(
                dragging: .project(exodus.id),
                onto: .folder(controlRoom.id),
                in: workspace
            ),
            .moveProject(exodus.id, toGroup: controlRoom.id, before: nil)
        )
    }

    func testDropPlannerMovesProjectBetweenFoldersAtRequestedPosition() {
        let relay = ProjectSidebarProject(name: "Relay", baseFolder: "/tmp/relay")
        let exodus = ProjectSidebarProject(name: "Exodus", baseFolder: "/tmp/exodus")
        let dataWrangler = ProjectSidebarProject(name: "Data Wrangler", baseFolder: "/tmp/data-wrangler")
        let controlRoom = ProjectSidebarGroup(name: "Control Room", projects: [relay, exodus])
        let archive = ProjectSidebarGroup(name: "Archive", projects: [dataWrangler])
        let workspace = ProjectSidebarWorkspace(groups: [controlRoom, archive])

        XCTAssertEqual(
            ProjectSidebarDropPlanner.plan(
                dragging: .project(dataWrangler.id),
                onto: .projects(groupID: controlRoom.id, index: 1),
                in: workspace
            ),
            .moveProject(dataWrangler.id, toGroup: controlRoom.id, before: exodus.id)
        )
    }

    func testDropPlannerReordersFoldersAtRequestedPosition() {
        let controlRoom = ProjectSidebarGroup(name: "Control Room")
        let clientWork = ProjectSidebarGroup(name: "Client Work")
        let archive = ProjectSidebarGroup(name: "Archive")
        let workspace = ProjectSidebarWorkspace(groups: [controlRoom, clientWork, archive])

        XCTAssertEqual(
            ProjectSidebarDropPlanner.plan(
                dragging: .group(archive.id),
                onto: .folders(index: 0),
                in: workspace
            ),
            .moveGroup(archive.id, before: controlRoom.id)
        )
    }

    func testDropPlannerOnlyReordersTerminalsWithinTheirProject() {
        let shell = ProjectSidebarTerminal(name: "Shell", launchDirectory: "/tmp")
        let logs = ProjectSidebarTerminal(name: "Logs", launchDirectory: "/tmp")
        let other = ProjectSidebarTerminal(name: "Other", launchDirectory: "/tmp")
        let relay = ProjectSidebarProject(
            name: "Relay",
            baseFolder: "/tmp/relay",
            terminals: [shell, logs]
        )
        let exodus = ProjectSidebarProject(
            name: "Exodus",
            baseFolder: "/tmp/exodus",
            terminals: [other]
        )
        let workspace = ProjectSidebarWorkspace(ungroupedProjects: [relay, exodus])

        XCTAssertEqual(
            ProjectSidebarDropPlanner.plan(
                dragging: .terminal(logs.id),
                onto: .terminals(projectID: relay.id, index: 0),
                in: workspace
            ),
            .moveTerminal(logs.id, before: shell.id)
        )
        XCTAssertNil(
            ProjectSidebarDropPlanner.plan(
                dragging: .terminal(logs.id),
                onto: .terminals(projectID: exodus.id, index: 0),
                in: workspace
            )
        )
    }

    func testDropPlannerAddsFinderFolderToFolderOrUngroupedProjects() {
        let controlRoom = ProjectSidebarGroup(name: "Control Room")
        let workspace = ProjectSidebarWorkspace(groups: [controlRoom])
        let url = URL(fileURLWithPath: "/tmp/relay")

        XCTAssertEqual(
            ProjectSidebarDropPlanner.plan(
                dragging: .folderURL(url),
                onto: .folder(controlRoom.id),
                in: workspace
            ),
            .createProject(url, inGroup: controlRoom.id)
        )
        XCTAssertEqual(
            ProjectSidebarDropPlanner.plan(
                dragging: .folderURL(url),
                onto: .projects(groupID: nil, index: 0),
                in: workspace
            ),
            .createProject(url, inGroup: nil)
        )
    }

    func testNativePasteboardItemsCarryStableSidebarIdentifiers() {
        let groupID = UUID()
        let projectID = UUID()
        let terminalID = UUID()

        XCTAssertEqual(
            ProjectSidebarPasteboard.item(for: .group(groupID))
                .string(forType: ProjectSidebarPasteboard.folderType),
            groupID.uuidString
        )
        XCTAssertEqual(
            ProjectSidebarPasteboard.item(for: .project(projectID))
                .string(forType: ProjectSidebarPasteboard.projectType),
            projectID.uuidString
        )
        XCTAssertEqual(
            ProjectSidebarPasteboard.item(for: .terminal(terminalID))
                .string(forType: ProjectSidebarPasteboard.terminalType),
            terminalID.uuidString
        )
    }

    func testDropPlannerRejectsCrossTypeDestinations() {
        let group = ProjectSidebarGroup(name: "Control Room")
        let project = ProjectSidebarProject(name: "Relay", baseFolder: "/tmp/relay")
        let terminal = ProjectSidebarTerminal(name: "Shell", launchDirectory: "/tmp")
        let workspace = ProjectSidebarWorkspace(groups: [group], ungroupedProjects: [project])

        XCTAssertNil(
            ProjectSidebarDropPlanner.plan(
                dragging: .group(group.id),
                onto: .projects(groupID: nil, index: 0),
                in: workspace
            )
        )
        XCTAssertNil(
            ProjectSidebarDropPlanner.plan(
                dragging: .terminal(terminal.id),
                onto: .folder(group.id),
                in: workspace
            )
        )
    }

    func testNativeOutlineObservesWorkspaceChangesAfterInitialState() {
        let initial = ProjectSidebarWorkspace.empty
        let relay = ProjectSidebarProject(name: "Relay", baseFolder: "/tmp/relay")
        let updated = ProjectSidebarWorkspace(ungroupedProjects: [relay])
        let subject = CurrentValueSubject<ProjectSidebarWorkspace, Never>(initial)
        var observed: [ProjectSidebarWorkspace] = []
        let changed = expectation(description: "structural workspace change")

        let observer = ProjectSidebarWorkspaceChangeObserver(
            publisher: subject.eraseToAnyPublisher()
        ) {
            observed.append($0)
            changed.fulfill()
        }
        subject.send(ProjectSidebarWorkspace(sidebarWidth: 320))
        subject.send(updated)

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(observed, [updated])
        withExtendedLifetime(observer) {}
    }

    func testNativeOutlineWaitsUntilPublishedWorkspaceIsInstalled() {
        let initial = ProjectSidebarWorkspace.empty
        let updated = ProjectSidebarWorkspace(
            ungroupedProjects: [ProjectSidebarProject(name: "Relay", baseFolder: "/tmp/relay")]
        )
        let subject = CurrentValueSubject<ProjectSidebarWorkspace, Never>(initial)
        var installed = initial
        let changed = expectation(description: "installed workspace is visible")

        let observer = ProjectSidebarWorkspaceChangeObserver(
            publisher: subject.eraseToAnyPublisher()
        ) { published in
            XCTAssertEqual(installed, published)
            changed.fulfill()
        }
        subject.send(updated)
        installed = updated

        wait(for: [changed], timeout: 1)
        withExtendedLifetime(observer) {}
    }

    func testOutlineTreeComparisonIgnoresWidthButDetectsAddedProject() {
        let initial = ProjectSidebarWorkspace.empty
        let widthOnly = ProjectSidebarWorkspace(sidebarWidth: 400)
        let withProject = ProjectSidebarWorkspace(
            ungroupedProjects: [ProjectSidebarProject(name: "Relay", baseFolder: "/tmp/relay")]
        )

        XCTAssertTrue(ProjectSidebarWorkspaceTree.isEqual(initial, widthOnly))
        XCTAssertFalse(ProjectSidebarWorkspaceTree.isEqual(initial, withProject))
    }

    func testSidebarWidthPersistenceBoundsAndDeduplicatesMeasurements() {
        XCTAssertNil(ProjectSidebarWidthPersistence.updatedWidth(current: 240, measured: 240.4))
        XCTAssertEqual(ProjectSidebarWidthPersistence.updatedWidth(current: 240, measured: 319.6), 320)
        XCTAssertEqual(ProjectSidebarWidthPersistence.updatedWidth(current: 240, measured: 100), 160)
        XCTAssertEqual(ProjectSidebarWidthPersistence.updatedWidth(current: 240, measured: 700), 560)
    }

    func testSidebarContextMenusUseRemoveLanguageAndOfferBackgroundCreation() {
        XCTAssertEqual(
            ProjectSidebarContextMenu.commands(for: .background),
            [.addFolder, .addProject]
        )
        XCTAssertEqual(
            ProjectSidebarContextMenu.commands(for: .folder),
            [.addProject, .rename, .separator, .removeFolder]
        )
        XCTAssertEqual(
            ProjectSidebarContextMenu.commands(for: .project(isGrouped: false)),
            [.newTerminal, .rename, .replaceBaseFolder, .separator, .removeProject]
        )
        XCTAssertEqual(
            ProjectSidebarContextMenu.commands(for: .terminal(canRetry: true)),
            [.rename, .retry, .changeFolder, .separator, .removeTerminal]
        )
        XCTAssertEqual(ProjectSidebarMenuCommand.removeFolder.title, "Remove Folder")
        XCTAssertEqual(ProjectSidebarMenuCommand.removeProject.title, "Remove Project")
        XCTAssertEqual(ProjectSidebarMenuCommand.removeTerminal.title, "Remove Terminal")
        XCTAssertEqual(ProjectSidebarToolbarMenu.commands, [.addProject, .addFolder])
    }

    func testNativeSplitRestoresPersistedSidebarWidth() {
        let splitView = ProjectSidebarNativeSplitView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 720)
        )
        splitView.isVertical = true
        splitView.addArrangedSubview(NSView())
        splitView.addArrangedSubview(NSView())
        splitView.layoutSubtreeIfNeeded()

        splitView.applySidebarWidth(318)

        XCTAssertEqual(splitView.subviews[0].frame.width, 318, accuracy: 1)
    }

    func testNativeSplitDoesNotReportWidthBeforeInitialRestoreCompletes() {
        let splitView = ProjectSidebarNativeSplitView()

        XCTAssertFalse(splitView.shouldReportSidebarWidthChanges)
        splitView.completeInitialWidthRestore()
        XCTAssertTrue(splitView.shouldReportSidebarWidthChanges)
    }

    func testSidebarScrollViewExpandsOutlineAndColumnWithViewport() {
        let scrollView = ProjectSidebarScrollView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 400)
        )
        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: .init("Sidebar"))
        outlineView.addTableColumn(column)
        scrollView.documentView = outlineView
        scrollView.layoutSubtreeIfNeeded()

        scrollView.setFrameSize(NSSize(width: 420, height: 400))
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(outlineView.frame.width, scrollView.contentSize.width, accuracy: 1)
        XCTAssertEqual(column.width, scrollView.contentSize.width, accuracy: 1)
    }

    func testSidebarHostingUpdatePreservesViewsForSameController() {
        let controller = NSObject()

        XCTAssertFalse(
            ProjectSidebarHostingUpdate.shouldReplaceController(
                current: controller,
                next: controller
            )
        )
        XCTAssertTrue(
            ProjectSidebarHostingUpdate.shouldReplaceController(
                current: controller,
                next: NSObject()
            )
        )
    }

    func testPersistedSidebarWidthAppliesToFreshNativeSplit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectSidebarStore(directoryURL: directory)
        try store.save(ProjectSidebarWorkspace(sidebarWidth: 347))
        let splitView = ProjectSidebarNativeSplitView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 720)
        )
        splitView.isVertical = true
        splitView.addArrangedSubview(NSView())
        splitView.addArrangedSubview(NSView())
        splitView.layoutSubtreeIfNeeded()

        splitView.applySidebarWidth(store.load().workspace.sidebarWidth)

        XCTAssertEqual(splitView.subviews[0].frame.width, 347, accuracy: 1)
    }

    func testSplitWidthLifecycleDoesNotOverwriteRestoreAndPersistsUserResize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectSidebarStore(directoryURL: directory)
        try store.save(ProjectSidebarWorkspace(sidebarWidth: 347))
        let splitView = ProjectSidebarNativeSplitView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 720)
        )
        splitView.isVertical = true
        splitView.addArrangedSubview(NSView())
        splitView.addArrangedSubview(NSView())
        splitView.layoutSubtreeIfNeeded()
        let widthCoordinator = ProjectSidebarSplitWidthCoordinator()
        splitView.sidebarWidthDidChangeByUser = { width in
            var workspace = store.load().workspace
            workspace.sidebarWidth = width
            try? store.save(workspace)
        }
        splitView.delegate = widthCoordinator

        splitView.commitUserSidebarWidth()
        XCTAssertEqual(store.load().workspace.sidebarWidth, 347)

        splitView.restoreInitialSidebarWidth(store.load().workspace.sidebarWidth)
        XCTAssertEqual(splitView.subviews[0].frame.width, 347, accuracy: 1)
        XCTAssertEqual(store.load().workspace.sidebarWidth, 347)

        splitView.setFrameSize(NSSize(width: 700, height: 720))
        XCTAssertEqual(store.load().workspace.sidebarWidth, 347)

        splitView.setFrameSize(NSSize(width: 1100, height: 720))
        XCTAssertEqual(splitView.subviews[0].frame.width, 347, accuracy: 1)

        splitView.setFrameSize(NSSize(width: 700, height: 720))
        splitView.setPosition(250, ofDividerAt: 0)
        splitView.commitUserSidebarWidth()
        XCTAssertEqual(store.load().workspace.sidebarWidth, 250)

        splitView.setFrameSize(NSSize(width: 1100, height: 720))
        XCTAssertEqual(splitView.subviews[0].frame.width, 250, accuracy: 1)

        splitView.setPosition(312, ofDividerAt: 0)
        splitView.commitUserSidebarWidth()
        XCTAssertEqual(store.load().workspace.sidebarWidth, 312)

        let relaunchedSplit = ProjectSidebarNativeSplitView(
            frame: NSRect(x: 0, y: 0, width: 1100, height: 720)
        )
        relaunchedSplit.isVertical = true
        relaunchedSplit.addArrangedSubview(NSView())
        relaunchedSplit.addArrangedSubview(NSView())
        relaunchedSplit.layoutSubtreeIfNeeded()
        relaunchedSplit.restoreInitialSidebarWidth(store.load().workspace.sidebarWidth)
        XCTAssertEqual(relaunchedSplit.subviews[0].frame.width, 312, accuracy: 1)
    }

    func testSidebarCellSupportsNativeInlineRenaming() {
        let cell = SidebarCell(identifier: .init("RenameCell"))

        cell.prepareForInlineRename()

        XCTAssertTrue(cell.titleField.isEditable)
        XCTAssertTrue(cell.titleField.isSelectable)
        XCTAssertTrue(cell.titleField.acceptsFirstResponder)
    }
}
