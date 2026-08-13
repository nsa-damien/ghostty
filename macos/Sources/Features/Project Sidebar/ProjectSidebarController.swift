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

    deinit {
        statusTimer?.invalidate()
    }

    var hasVisibleWindow: Bool {
        windowController?.window?.isVisible == true
    }

    var isRestorationAuthority: Bool { true }

    func show() {
        if windowController == nil {
            windowController = ProjectSidebarWindowController(sidebarController: self)
        }
        windowController?.showWindow(self)
        windowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        windowController?.window?.orderOut(self)
    }

    func createProject(baseFolder: String, name: String? = nil) throws -> UUID {
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(baseFolder) else {
            throw ProjectSidebarMutationError.baseFolderUnavailable
        }
        let folderKey = ProjectSidebarWorkspaceValidator.canonicalFolderKey(baseFolder)
        guard !workspace.projects.contains(where: {
            ProjectSidebarWorkspaceValidator.canonicalFolderKey($0.baseFolder) == folderKey
        }) else {
            throw ProjectSidebarMutationError.duplicateBaseFolder
        }

        let folderName = URL(fileURLWithPath: baseFolder).lastPathComponent
        let projectName = ProjectSidebarWorkspaceValidator.displayName(name ?? folderName)
        let entry = ProjectSidebarTerminal(name: "Terminal 1", launchDirectory: baseFolder)
        let project = ProjectSidebarProject(name: projectName, baseFolder: baseFolder, ungroupedEntries: [entry])
        var updated = workspace
        updated.projects.append(project)
        try commit(updated)
        selectedProjectID = project.id
        selectedEntryID = entry.id
        _ = launch(entryID: entry.id)
        return project.id
    }

    func createProjectFromFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Project"
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url, let self else { return }
            do {
                _ = try self.createProject(baseFolder: folder.path)
            } catch {
                self.present(error: error)
            }
        }
    }

    @discardableResult
    func createTerminal(in projectID: UUID, name: String? = nil, launchDirectory: String? = nil) throws -> UUID {
        guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        let project = workspace.projects[projectIndex]
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(project.baseFolder) else {
            throw ProjectSidebarMutationError.baseFolderUnavailable
        }
        let nextName = name ?? "Terminal \(project.allEntries.count + 1)"
        let entry = ProjectSidebarTerminal(
            name: nextName,
            launchDirectory: launchDirectory ?? project.baseFolder
        )
        var updated = workspace
        updated.projects[projectIndex].ungroupedEntries.append(entry)
        try commit(updated)
        selectedProjectID = projectID
        selectedEntryID = entry.id
        _ = launch(entryID: entry.id)
        return entry.id
    }

    func select(projectID: UUID) {
        selectedProjectID = projectID
        selectedEntryID = nil
    }

    func select(entryID: UUID) {
        guard let location = location(of: entryID) else { return }
        selectedProjectID = location.projectID
        selectedEntryID = entryID
        _ = launch(entryID: entryID)
    }

    @discardableResult
    func launch(entryID: UUID) -> Bool {
        guard let entry = entry(entryID: entryID) else { return false }
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(entry.launchDirectory) else {
            launchFailures.insert(entryID)
            return false
        }
        let runtime = runtimeRegistry.start(entryID: entryID, ghostty: ghostty, launchDirectory: entry.launchDirectory)
        if runtime.controller.surfaceTree.first?.error != nil {
            runtimeRegistry.stop(entryID: entryID)
            launchFailures.insert(entryID)
            return false
        }
        launchFailures.remove(entryID)
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
        location(of: entryID).flatMap { location in
            switch location.groupID {
            case nil:
                return workspace.projects[location.projectIndex].ungroupedEntries.first(where: { $0.id == entryID })
            case .some(let groupID):
                return workspace.projects[location.projectIndex].groups.first(where: { $0.id == groupID })?.entries.first(where: { $0.id == entryID })
            }
        }
    }

    func projectName(for projectID: UUID) -> String? {
        workspace.projects.first(where: { $0.id == projectID })?.name
    }

    func renameProject(_ projectID: UUID, to name: String) throws {
        guard let index = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        var updated = workspace
        updated.projects[index].name = name
        try commit(updated)
    }

    func createGroup(in projectID: UUID, name: String) throws -> UUID {
        guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        let group = ProjectSidebarGroup(name: name)
        var updated = workspace
        updated.projects[projectIndex].groups.append(group)
        try commit(updated)
        return group.id
    }

    func renameGroup(_ groupID: UUID, in projectID: UUID, to name: String) throws {
        guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        guard let groupIndex = workspace.projects[projectIndex].groups.firstIndex(where: { $0.id == groupID }) else {
            throw ProjectSidebarMutationError.groupNotFound
        }
        var updated = workspace
        updated.projects[projectIndex].groups[groupIndex].name = name
        try commit(updated)
    }

    func renameTerminal(_ entryID: UUID, to name: String) throws {
        guard let location = location(of: entryID) else {
            throw ProjectSidebarMutationError.terminalNotFound
        }
        var updated = workspace
        if let groupID = location.groupID,
           let groupIndex = updated.projects[location.projectIndex].groups.firstIndex(where: { $0.id == groupID }),
           let entryIndex = updated.projects[location.projectIndex].groups[groupIndex].entries.firstIndex(where: { $0.id == entryID }) {
            updated.projects[location.projectIndex].groups[groupIndex].entries[entryIndex].name = name
        } else if let entryIndex = updated.projects[location.projectIndex].ungroupedEntries.firstIndex(where: { $0.id == entryID }) {
            updated.projects[location.projectIndex].ungroupedEntries[entryIndex].name = name
        }
        try commit(updated)
    }

    func moveTerminal(_ entryID: UUID, toGroup groupID: UUID?) throws {
        guard let location = location(of: entryID) else {
            throw ProjectSidebarMutationError.terminalNotFound
        }
        var updated = workspace
        let project = updated.projects[location.projectIndex]
        var entry: ProjectSidebarTerminal?
        if let sourceGroupID = location.groupID,
           let sourceIndex = project.groups.firstIndex(where: { $0.id == sourceGroupID }) {
            entry = updated.projects[location.projectIndex].groups[sourceIndex].entries.remove(
                at: project.groups[sourceIndex].entries.firstIndex(where: { $0.id == entryID })!
            )
        } else if let sourceIndex = project.ungroupedEntries.firstIndex(where: { $0.id == entryID }) {
            entry = updated.projects[location.projectIndex].ungroupedEntries.remove(at: sourceIndex)
        }
        guard let entry else { throw ProjectSidebarMutationError.terminalNotFound }

        if let groupID {
            guard let groupIndex = updated.projects[location.projectIndex].groups.firstIndex(where: { $0.id == groupID }) else {
                throw ProjectSidebarMutationError.groupNotFound
            }
            updated.projects[location.projectIndex].groups[groupIndex].entries.append(entry)
        } else {
            updated.projects[location.projectIndex].ungroupedEntries.append(entry)
        }
        try commit(updated)
    }

    func replaceProjectBaseFolder(_ projectID: UUID, with folder: String) throws {
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(folder) else {
            throw ProjectSidebarMutationError.baseFolderUnavailable
        }
        guard let index = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        let folderKey = ProjectSidebarWorkspaceValidator.canonicalFolderKey(folder)
        guard !workspace.projects.enumerated().contains(where: { offset, project in
            offset != index && ProjectSidebarWorkspaceValidator.canonicalFolderKey(project.baseFolder) == folderKey
        }) else {
            throw ProjectSidebarMutationError.duplicateBaseFolder
        }
        var updated = workspace
        updated.projects[index].baseFolder = folder
        try commit(updated)
    }

    func replaceTerminalDirectory(_ entryID: UUID, with folder: String) throws {
        guard ProjectSidebarWorkspaceValidator.isDirectoryAvailable(folder) else {
            throw ProjectSidebarMutationError.terminalDirectoryUnavailable
        }
        guard let location = location(of: entryID) else {
            throw ProjectSidebarMutationError.terminalNotFound
        }
        var updated = workspace
        if let groupID = location.groupID,
           let groupIndex = updated.projects[location.projectIndex].groups.firstIndex(where: { $0.id == groupID }),
           let entryIndex = updated.projects[location.projectIndex].groups[groupIndex].entries.firstIndex(where: { $0.id == entryID }) {
            updated.projects[location.projectIndex].groups[groupIndex].entries[entryIndex].launchDirectory = folder
        } else if let entryIndex = updated.projects[location.projectIndex].ungroupedEntries.firstIndex(where: { $0.id == entryID }) {
            updated.projects[location.projectIndex].ungroupedEntries[entryIndex].launchDirectory = folder
        }
        try commit(updated)
        launchFailures.remove(entryID)
    }

    func deleteGroup(_ groupID: UUID, in projectID: UUID) throws {
        guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        guard let groupIndex = workspace.projects[projectIndex].groups.firstIndex(where: { $0.id == groupID }) else {
            throw ProjectSidebarMutationError.groupNotFound
        }
        var updated = workspace
        let group = updated.projects[projectIndex].groups.remove(at: groupIndex)
        updated.projects[projectIndex].ungroupedEntries.append(contentsOf: group.entries)
        try commit(updated)
    }

    @discardableResult
    func deleteTerminal(_ entryID: UUID, confirmRunning: Bool = true) -> Bool {
        guard let location = location(of: entryID) else { return false }
        let isRunning = runtimeRegistry.isRunning(entryID: entryID)
        if isRunning && confirmRunning {
            let alert = NSAlert()
            alert.messageText = "Delete Terminal?"
            alert.informativeText = "This will stop the running terminal."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }

        var updated = workspace
        if let groupID = location.groupID,
           let groupIndex = updated.projects[location.projectIndex].groups.firstIndex(where: { $0.id == groupID }) {
            updated.projects[location.projectIndex].groups[groupIndex].entries.removeAll(where: { $0.id == entryID })
        } else {
            updated.projects[location.projectIndex].ungroupedEntries.removeAll(where: { $0.id == entryID })
        }
        do {
            try commit(updated)
        } catch {
            return false
        }
        runtimeRegistry.stop(entryID: entryID)
        launchFailures.remove(entryID)
        if selectedEntryID == entryID { selectedEntryID = nil }
        return true
    }

    @discardableResult
    func deleteProject(_ projectID: UUID, confirm: Bool = true) -> Bool {
        guard let project = workspace.projects.first(where: { $0.id == projectID }) else { return false }
        let entryIDs = project.allEntries.map(\.id)
        let runningCount = entryIDs.filter { runtimeRegistry.isRunning(entryID: $0) }.count
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Delete Project?"
            alert.informativeText = "This will stop \(runningCount) running terminal\(runningCount == 1 ? "" : "s")."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        var updated = workspace
        updated.projects.removeAll(where: { $0.id == projectID })
        do {
            try commit(updated)
        } catch {
            return false
        }
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

    private func chooseFolder(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url.path)
        }
    }

    func reorderProjects(from source: Int, to destination: Int) throws {
        guard workspace.projects.indices.contains(source), workspace.projects.indices.contains(destination) else { return }
        var updated = workspace
        let project = updated.projects.remove(at: source)
        updated.projects.insert(project, at: min(destination, updated.projects.count))
        try commit(updated)
    }

    func reorderGroups(in projectID: UUID, from source: Int, to destination: Int) throws {
        guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        guard workspace.projects[projectIndex].groups.indices.contains(source),
              workspace.projects[projectIndex].groups.indices.contains(destination) else { return }
        var updated = workspace
        let group = updated.projects[projectIndex].groups.remove(at: source)
        updated.projects[projectIndex].groups.insert(group, at: min(destination, updated.projects[projectIndex].groups.count))
        try commit(updated)
    }

    func reorderTerminals(in projectID: UUID, groupID: UUID?, from source: Int, to destination: Int) throws {
        guard let projectIndex = workspace.projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectSidebarMutationError.projectNotFound
        }
        var updated = workspace
        if let groupID {
            guard let groupIndex = updated.projects[projectIndex].groups.firstIndex(where: { $0.id == groupID }) else {
                throw ProjectSidebarMutationError.groupNotFound
            }
            guard updated.projects[projectIndex].groups[groupIndex].entries.indices.contains(source),
                  updated.projects[projectIndex].groups[groupIndex].entries.indices.contains(destination) else { return }
            let entry = updated.projects[projectIndex].groups[groupIndex].entries.remove(at: source)
            updated.projects[projectIndex].groups[groupIndex].entries.insert(entry, at: min(destination, updated.projects[projectIndex].groups[groupIndex].entries.count))
        } else {
            guard updated.projects[projectIndex].ungroupedEntries.indices.contains(source),
                  updated.projects[projectIndex].ungroupedEntries.indices.contains(destination) else { return }
            let entry = updated.projects[projectIndex].ungroupedEntries.remove(at: source)
            updated.projects[projectIndex].ungroupedEntries.insert(entry, at: min(destination, updated.projects[projectIndex].ungroupedEntries.count))
        }
        try commit(updated)
    }

    func location(of entryID: UUID) -> (projectIndex: Int, projectID: UUID, groupID: UUID?)? {
        for (projectIndex, project) in workspace.projects.enumerated() {
            if project.ungroupedEntries.contains(where: { $0.id == entryID }) {
                return (projectIndex, project.id, nil)
            }
            for group in project.groups where group.entries.contains(where: { $0.id == entryID }) {
                return (projectIndex, project.id, group.id)
            }
        }
        return nil
    }

    func runtime(for entryID: UUID) -> ProjectSidebarRuntime? {
        runtimeRegistry.runtime(for: entryID)
    }

    func performNewTerminal() {
        if let projectID = selectedProjectID {
            do { _ = try createTerminal(in: projectID) } catch { present(error: error) }
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
        for projectIndex in updated.projects.indices {
            if updated.projects[projectIndex].id == id {
                updated.projects[projectIndex].isExpanded = expanded
                try? commit(updated)
                return
            }
            if let groupIndex = updated.projects[projectIndex].groups.firstIndex(where: { $0.id == id }) {
                updated.projects[projectIndex].groups[groupIndex].isExpanded = expanded
                try? commit(updated)
                return
            }
        }
    }

    func setSidebarVisible(_ visible: Bool) {
        var updated = workspace
        updated.sidebarVisible = visible
        try? commit(updated)
    }

    func setSidebarWidth(_ width: Double) {
        var updated = workspace
        updated.sidebarWidth = min(
            ProjectSidebarWorkspaceValidator.maximumSidebarWidth,
            max(ProjectSidebarWorkspaceValidator.minimumSidebarWidth, width)
        )
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
        runtimeRegistry.stopAll()
        return .terminateNow
    }

    func stopAllRuntimes() {
        runtimeRegistry.stopAll()
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
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
