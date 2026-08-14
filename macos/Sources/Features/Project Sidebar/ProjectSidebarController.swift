import AppKit
import Combine
import Foundation
import GhosttyKit
import SwiftUI

enum ProjectSidebarMutationError: Error, Equatable, LocalizedError {
    case projectNotFound
    case groupNotFound
    case terminalNotFound
    case duplicateBaseFolder
    case baseFolderUnavailable
    case invalidName(ProjectSidebarValidationError)
    case terminalDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .projectNotFound: "Project not found."
        case .groupNotFound: "Group not found."
        case .terminalNotFound: "Terminal entry not found."
        case .duplicateBaseFolder: "That folder is already assigned to a project."
        case .baseFolderUnavailable: "Choose an existing folder."
        case .invalidName(let error): error.localizedDescription
        case .terminalDirectoryUnavailable: "That terminal folder is not available."
        }
    }
}

final class ProjectSidebarController: NSObject, ObservableObject {
    let ghostty: Ghostty.App
    let runtimeRegistry = ProjectSidebarRuntimeRegistry()

    @Published private(set) var workspace: ProjectSidebarWorkspace
    @Published private(set) var selectedProjectID: UUID?
    @Published private(set) var selectedEntryID: UUID?
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var launchFailures: Set<UUID> = []

    private let store: ProjectSidebarStore
    private var windowController: ProjectSidebarWindowController?
    private var statusTimer: Timer?

    init(ghostty: Ghostty.App, store: ProjectSidebarStore = .default) {
        self.ghostty = ghostty
        self.store = store
        let result = store.load()
        self.workspace = result.workspace
        self.recoveryNotice = result.notice
        super.init()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit { statusTimer?.invalidate() }

    var hasKeyWindow: Bool { windowController?.window?.isKeyWindow == true }
    var isRestorationAuthority: Bool { !workspace.projects.isEmpty }

    func show() {
        if windowController == nil {
            windowController = ProjectSidebarWindowController(sidebarController: self)
        }
        windowController?.showWindow(self)
        windowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
        updateRuntimeFocus()
    }

    func hide() {
        windowController?.window?.orderOut(self)
        updateRuntimeFocus()
    }

    @discardableResult
    func createProject(baseFolder: String, name: String? = nil, inGroup groupID: UUID? = nil) throws -> UUID {
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(baseFolder) else {
            throw ProjectSidebarMutationError.baseFolderUnavailable
        }
        let folderKey = ProjectSidebarWorkspaceValidator.canonicalFolderKey(baseFolder)
        guard !workspace.projects.contains(where: {
            ProjectSidebarWorkspaceValidator.canonicalFolderKey($0.baseFolder) == folderKey
        }) else {
            throw ProjectSidebarMutationError.duplicateBaseFolder
        }
        if let groupID, !workspace.groups.contains(where: { $0.id == groupID }) {
            throw ProjectSidebarMutationError.groupNotFound
        }

        let folderName = URL(fileURLWithPath: baseFolder).lastPathComponent
        let projectName = ProjectSidebarWorkspaceValidator.displayName(name ?? folderName)
        let terminal = ProjectSidebarTerminal(name: "Terminal 1", launchDirectory: baseFolder)
        let project = ProjectSidebarProject(name: projectName, baseFolder: baseFolder, terminals: [terminal])
        var updated = workspace
        guard updated.appendProject(project, toGroup: groupID) else {
            throw ProjectSidebarMutationError.groupNotFound
        }
        try commit(updated)
        selectedProjectID = project.id
        selectedEntryID = terminal.id
        _ = launch(entryID: terminal.id)
        return project.id
    }

    func createProjectFromFolderPicker(inGroup groupID: UUID? = nil) {
        chooseFolder(prompt: "Create Project") { [weak self] folder in
            guard let self else { return }
            do {
                _ = try createProject(baseFolder: folder, inGroup: groupID)
            } catch {
                present(error: error)
            }
        }
    }

    func createProjectFromDroppedFolder(_ url: URL, inGroup groupID: UUID? = nil) {
        guard url.isFileURL else { return }
        do {
            _ = try createProject(baseFolder: url.path, inGroup: groupID)
        } catch {
            present(error: error)
        }
    }

    @discardableResult
    func createGroup(name: String? = nil) throws -> UUID {
        let defaultName = nextAvailableGroupName()
        let group = ProjectSidebarGroup(name: name ?? defaultName)
        var updated = workspace
        updated.groups.append(group)
        try commit(updated)
        return group.id
    }

    @discardableResult
    func createTerminal(in projectID: UUID, name: String? = nil, launchDirectory: String? = nil) throws -> UUID {
        guard let location = workspace.location(ofProject: projectID) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        var project = workspace.project(at: location)
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(project.baseFolder) else {
            throw ProjectSidebarMutationError.baseFolderUnavailable
        }
        let terminal = ProjectSidebarTerminal(
            name: name ?? nextAvailableTerminalName(in: project),
            launchDirectory: launchDirectory ?? project.baseFolder
        )
        project.terminals.append(terminal)
        var updated = workspace
        updated.replaceProject(at: location, with: project)
        try commit(updated)
        selectedProjectID = projectID
        selectedEntryID = terminal.id
        _ = launch(entryID: terminal.id)
        return terminal.id
    }

    func select(projectID: UUID) {
        selectedProjectID = projectID
        selectedEntryID = nil
        updateRuntimeFocus()
    }

    func select(entryID: UUID) {
        guard let location = location(of: entryID) else { return }
        selectedProjectID = location.projectID
        selectedEntryID = entryID
        _ = launch(entryID: entryID)
        updateRuntimeFocus()
    }

    @discardableResult
    func launch(entryID: UUID) -> Bool {
        guard let entry = entry(entryID: entryID) else { return false }
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(entry.launchDirectory) else {
            launchFailures.insert(entryID)
            return false
        }
        let runtime = runtimeRegistry.start(
            entryID: entryID,
            ghostty: ghostty,
            launchDirectory: entry.launchDirectory
        )
        if runtime.controller.surfaceTree.first?.error != nil {
            runtimeRegistry.stop(entryID: entryID)
            launchFailures.insert(entryID)
            return false
        }
        launchFailures.remove(entryID)
        updateRuntimeFocus()
        return true
    }

    func entryStatus(_ entryID: UUID) -> ProjectSidebarEntryStatus {
        guard let entry = entry(entryID: entryID) else { return .stopped }
        if let runtime = runtimeRegistry.runtime(for: entryID), runtime.status == .running {
            return .running
        }
        return ProjectSidebarWorkspaceValidator.isDirectoryAvailable(entry.launchDirectory) ? .stopped : .unavailable
    }

    func entry(entryID: UUID) -> ProjectSidebarTerminal? {
        guard let location = location(of: entryID) else { return nil }
        return workspace.project(at: location.projectLocation).terminals[location.entryIndex]
    }

    func projectName(for projectID: UUID) -> String? {
        guard let location = workspace.location(ofProject: projectID) else { return nil }
        return workspace.project(at: location).name
    }

    func renameProject(_ projectID: UUID, to name: String) throws {
        guard let location = workspace.location(ofProject: projectID) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        var project = workspace.project(at: location)
        project.name = name
        var updated = workspace
        updated.replaceProject(at: location, with: project)
        try commit(updated)
    }

    func renameGroup(_ groupID: UUID, to name: String) throws {
        guard let groupIndex = workspace.groups.firstIndex(where: { $0.id == groupID }) else {
            throw ProjectSidebarMutationError.groupNotFound
        }
        var updated = workspace
        updated.groups[groupIndex].name = name
        try commit(updated)
    }

    func renameTerminal(_ entryID: UUID, to name: String) throws {
        guard let location = location(of: entryID) else {
            throw ProjectSidebarMutationError.terminalNotFound
        }
        var project = workspace.project(at: location.projectLocation)
        project.terminals[location.entryIndex].name = name
        var updated = workspace
        updated.replaceProject(at: location.projectLocation, with: project)
        try commit(updated)
    }

    func moveProject(_ projectID: UUID, toGroup groupID: UUID?, before destinationID: UUID? = nil) throws {
        guard workspace.location(ofProject: projectID) != nil else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        if let groupID {
            guard workspace.groups.contains(where: { $0.id == groupID }) else {
                throw ProjectSidebarMutationError.groupNotFound
            }
        }
        var updated = workspace
        guard updated.moveProject(projectID, toGroup: groupID, before: destinationID) else { return }
        try commit(updated)
    }

    func moveGroup(_ groupID: UUID, before destinationID: UUID?) throws {
        guard workspace.groups.contains(where: { $0.id == groupID }) else {
            throw ProjectSidebarMutationError.groupNotFound
        }
        var updated = workspace
        guard updated.moveGroup(groupID, before: destinationID) else { return }
        try commit(updated)
    }

    func performSidebarMutation(_ mutation: () throws -> Void) {
        do {
            try mutation()
        } catch {
            present(error: error)
        }
    }

    func replaceProjectBaseFolder(_ projectID: UUID, with folder: String) throws {
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(folder) else {
            throw ProjectSidebarMutationError.baseFolderUnavailable
        }
        guard let location = workspace.location(ofProject: projectID) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        let folderKey = ProjectSidebarWorkspaceValidator.canonicalFolderKey(folder)
        guard !workspace.projects.contains(where: {
            $0.id != projectID && ProjectSidebarWorkspaceValidator.canonicalFolderKey($0.baseFolder) == folderKey
        }) else {
            throw ProjectSidebarMutationError.duplicateBaseFolder
        }
        var project = workspace.project(at: location)
        project.baseFolder = folder
        var updated = workspace
        updated.replaceProject(at: location, with: project)
        try commit(updated)
    }

    func replaceTerminalDirectory(_ entryID: UUID, with folder: String) throws {
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(folder) else {
            throw ProjectSidebarMutationError.terminalDirectoryUnavailable
        }
        guard let location = location(of: entryID) else {
            throw ProjectSidebarMutationError.terminalNotFound
        }
        var project = workspace.project(at: location.projectLocation)
        project.terminals[location.entryIndex].launchDirectory = folder
        var updated = workspace
        updated.replaceProject(at: location.projectLocation, with: project)
        try commit(updated)
        launchFailures.remove(entryID)
    }

    func deleteGroup(_ groupID: UUID) throws {
        guard let groupIndex = workspace.groups.firstIndex(where: { $0.id == groupID }) else {
            throw ProjectSidebarMutationError.groupNotFound
        }
        var updated = workspace
        let group = updated.groups.remove(at: groupIndex)
        updated.ungroupedProjects.append(contentsOf: group.projects)
        try commit(updated)
    }

    @discardableResult
    func deleteTerminal(_ entryID: UUID, confirmRunning: Bool = true) -> Bool {
        guard let location = location(of: entryID) else { return false }
        if runtimeRegistry.isRunning(entryID: entryID) && confirmRunning {
            let alert = NSAlert()
            alert.messageText = "Remove Terminal?"
            alert.informativeText = "This removes the terminal from the project and stops its running session. Files on disk are not affected."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        var project = workspace.project(at: location.projectLocation)
        project.terminals.remove(at: location.entryIndex)
        var updated = workspace
        updated.replaceProject(at: location.projectLocation, with: project)
        do { try commit(updated) } catch { return false }
        runtimeRegistry.stop(entryID: entryID)
        launchFailures.remove(entryID)
        if selectedEntryID == entryID { selectedEntryID = nil }
        return true
    }

    @discardableResult
    func deleteProject(_ projectID: UUID, confirm: Bool = true) -> Bool {
        guard let location = workspace.location(ofProject: projectID) else { return false }
        let project = workspace.project(at: location)
        let entryIDs = project.terminals.map(\.id)
        let runningCount = entryIDs.filter { runtimeRegistry.isRunning(entryID: $0) }.count
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Remove Project?"
            alert.informativeText = "This removes the project from the sidebar and stops \(runningCount) running terminal\(runningCount == 1 ? "" : "s"). Files on disk are not affected."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        var updated = workspace
        updated.removeProject(at: location)
        do { try commit(updated) } catch { return false }
        entryIDs.forEach { runtimeRegistry.stop(entryID: $0); launchFailures.remove($0) }
        if selectedProjectID == projectID {
            selectedProjectID = nil
            selectedEntryID = nil
        }
        return true
    }

    func chooseReplacementFolder(forProject projectID: UUID) {
        chooseFolder { [weak self] folder in
            try? self?.replaceProjectBaseFolder(projectID, with: folder)
        }
    }

    func chooseReplacementFolder(forEntry entryID: UUID) {
        chooseFolder { [weak self] folder in
            try? self?.replaceTerminalDirectory(entryID, with: folder)
        }
    }

    func moveTerminal(_ entryID: UUID, before destinationID: UUID?) throws {
        guard let source = location(of: entryID) else {
            throw ProjectSidebarMutationError.terminalNotFound
        }
        var project = workspace.project(at: source.projectLocation)
        let destination = destinationID.flatMap { id in project.terminals.firstIndex(where: { $0.id == id }) }
            ?? project.terminals.count
        guard moveItem(in: &project.terminals, from: source.entryIndex, to: destination) else { return }
        var updated = workspace
        updated.replaceProject(at: source.projectLocation, with: project)
        try commit(updated)
    }

    func location(of entryID: UUID) -> (
        projectLocation: ProjectSidebarProjectLocation,
        projectID: UUID,
        entryIndex: Int
    )? {
        for project in workspace.projects {
            guard let entryIndex = project.terminals.firstIndex(where: { $0.id == entryID }),
                  let projectLocation = workspace.location(ofProject: project.id) else { continue }
            return (projectLocation, project.id, entryIndex)
        }
        return nil
    }

    func runtime(for entryID: UUID) -> ProjectSidebarRuntime? {
        runtimeRegistry.runtime(for: entryID)
    }

    func performNewTerminal() {
        if let selectedProjectID {
            do { _ = try createTerminal(in: selectedProjectID) } catch { present(error: error) }
        } else {
            createProjectFromFolderPicker()
        }
    }

    func performCloseSelectedTerminal() {
        guard let selectedEntryID else { return }
        runtimeRegistry.stop(entryID: selectedEntryID)
        self.selectedEntryID = nil
    }

    func setExpanded(id: UUID, expanded: Bool) {
        var updated = workspace
        if let groupIndex = updated.groups.firstIndex(where: { $0.id == id }) {
            updated.groups[groupIndex].isExpanded = expanded
            try? commit(updated)
            return
        }
        guard let location = updated.location(ofProject: id) else { return }
        var project = updated.project(at: location)
        project.isExpanded = expanded
        updated.replaceProject(at: location, with: project)
        try? commit(updated)
    }

    func setSidebarVisible(_ visible: Bool) {
        var updated = workspace
        updated.sidebarVisible = visible
        try? commit(updated)
    }

    func setSidebarWidth(_ width: Double) {
        guard let width = ProjectSidebarWidthPersistence.updatedWidth(
            current: workspace.sidebarWidth,
            measured: width
        ) else { return }
        var updated = workspace
        updated.sidebarWidth = width
        try? commit(updated)
    }

    func confirmQuit() -> NSApplication.TerminateReply {
        let count = runtimeRegistry.runningEntryCount
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Ghostty?"
        alert.informativeText = "\(count) running session\(count == 1 ? "" : "s") will stop."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return .terminateNow
    }

    func stopAllRuntimes() { runtimeRegistry.stopAll() }

    func updateRuntimeFocus() {
        for (entryID, runtime) in runtimeRegistry.runtimes {
            runtime.controller.setExternallyManagedWindowKeyState(
                hasKeyWindow && entryID == selectedEntryID
            )
        }
    }

    private func chooseFolder(prompt: String = "Choose Folder", _ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url.path)
        }
    }

    private func nextAvailableGroupName() -> String {
        let names = Set(workspace.groups.map { ProjectSidebarWorkspaceValidator.normalizedName($0.name) })
        var number = 1
        while names.contains("group \(number)") { number += 1 }
        return "Group \(number)"
    }

    private func nextAvailableTerminalName(in project: ProjectSidebarProject) -> String {
        let names = Set(project.terminals.map { ProjectSidebarWorkspaceValidator.normalizedName($0.name) })
        var number = 1
        while names.contains("terminal \(number)") { number += 1 }
        return "Terminal \(number)"
    }

    private func moveItem<Element>(in values: inout [Element], from source: Int, to destination: Int) -> Bool {
        guard values.indices.contains(source), destination >= 0, destination <= values.count else { return false }
        let value = values.remove(at: source)
        let adjustedDestination = destination > source ? destination - 1 : destination
        values.insert(value, at: min(adjustedDestination, values.count))
        return true
    }

    private func commit(_ updated: ProjectSidebarWorkspace) throws {
        do {
            try store.save(updated)
        } catch let error as ProjectSidebarStoreError {
            if case .invalidWorkspace(let validation) = error {
                throw ProjectSidebarMutationError.invalidName(validation)
            }
            throw error
        }
        workspace = updated
    }

    private func present(error: Error) {
        NSAlert(error: error).runModal()
    }
}
