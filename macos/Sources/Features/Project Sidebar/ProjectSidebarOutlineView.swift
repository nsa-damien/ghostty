import AppKit
import Combine
import SwiftUI

enum ProjectSidebarPasteboard {
    static let folderType = NSPasteboard.PasteboardType("com.mitchellh.ghostty.project-sidebar.folder")
    static let projectType = NSPasteboard.PasteboardType("com.mitchellh.ghostty.project-sidebar.project")
    static let terminalType = NSPasteboard.PasteboardType("com.mitchellh.ghostty.project-sidebar.terminal")

    static func item(for dragged: ProjectSidebarDraggedItem) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        switch dragged {
        case .group(let id): item.setString(id.uuidString, forType: folderType)
        case .project(let id): item.setString(id.uuidString, forType: projectType)
        case .terminal(let id): item.setString(id.uuidString, forType: terminalType)
        case .folderURL(let url): item.setString(url.absoluteString, forType: .fileURL)
        }
        return item
    }
}

enum ProjectSidebarMenuCommand: Hashable {
    case addFolder
    case addProject
    case newTerminal
    case rename
    case tag
    case retry
    case changeFolder
    case removeFolder
    case removeProject
    case removeTerminal
    case separator

    var title: String? {
        switch self {
        case .addFolder: "Add Folder"
        case .addProject: "Add Project"
        case .newTerminal: "New Terminal"
        case .rename: "Rename"
        case .tag: "Tags"
        case .retry: "Retry"
        case .changeFolder: "Change Folder"
        case .removeFolder: "Remove Folder"
        case .removeProject: "Remove Project"
        case .removeTerminal: "Remove Terminal"
        case .separator: nil
        }
    }
}

enum ProjectSidebarContextMenuTarget: Equatable {
    case background
    case folder
    case project
    case terminal(canRetry: Bool)
}

enum ProjectSidebarContextMenu {
    static func commands(for target: ProjectSidebarContextMenuTarget) -> [ProjectSidebarMenuCommand] {
        switch target {
        case .background:
            [.addFolder, .addProject]
        case .folder:
            [.addProject, .rename, .tag, .separator, .removeFolder]
        case .project:
            [.newTerminal, .rename, .tag, .separator, .removeProject]
        case .terminal(let canRetry):
            [.rename]
                + (canRetry ? [.retry] : [])
                + [.changeFolder, .separator, .removeTerminal]
        }
    }
}

enum ProjectSidebarWorkspaceTree {
    static func isEqual(_ lhs: ProjectSidebarWorkspace, _ rhs: ProjectSidebarWorkspace) -> Bool {
        lhs.groups == rhs.groups && lhs.ungroupedProjects == rhs.ungroupedProjects
    }
}

final class ProjectSidebarWorkspaceChangeObserver {
    private var cancellable: AnyCancellable?

    init(
        publisher: AnyPublisher<ProjectSidebarWorkspace, Never>,
        onChange: @escaping (ProjectSidebarWorkspace) -> Void
    ) {
        cancellable = publisher
            .removeDuplicates(by: ProjectSidebarWorkspaceTree.isEqual)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: onChange)
    }
}

struct ProjectSidebarOutlineView: NSViewRepresentable {
    let controller: ProjectSidebarController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(controller: controller)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        private var controller: ProjectSidebarController
        private let outlineView = NativeOutlineView()
        private var roots: [Node] = []
        private var foldersSection: Node?
        private var projectsSection: Node?
        private var lastWorkspace: ProjectSidebarWorkspace?
        private var restoringState = false
        private var editingNode: Node?
        private var renameError: String?
        private var menuNode: Node?
        private var workspaceObserver: ProjectSidebarWorkspaceChangeObserver?

        init(controller: ProjectSidebarController) {
            self.controller = controller
            super.init()
            observeWorkspaceChanges()
        }

        func makeScrollView() -> NSScrollView {
            let column = NSTableColumn(identifier: .init("ProjectSidebarColumn"))
            column.resizingMask = .autoresizingMask

            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
            outlineView.headerView = nil
            outlineView.dataSource = self
            outlineView.delegate = self
            outlineView.style = .sourceList
            outlineView.rowSizeStyle = .default
            outlineView.indentationPerLevel = 16
            outlineView.autoresizesOutlineColumn = true
            outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            outlineView.autoresizingMask = [.width]
            outlineView.allowsEmptySelection = true
            outlineView.registerForDraggedTypes([
                ProjectSidebarPasteboard.folderType,
                ProjectSidebarPasteboard.projectType,
                ProjectSidebarPasteboard.terminalType,
                .fileURL,
            ])
            outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
            outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
            outlineView.target = self
            outlineView.doubleAction = #selector(beginRenameFromDoubleClick)
            outlineView.menuProvider = { [weak self] node in self?.menu(for: node) }
            outlineView.renameAction = { [weak self] in self?.beginRenameForSelectedRow() }
            outlineView.deleteAction = { [weak self] in self?.deleteSelectedRow() }

            let scrollView = ProjectSidebarScrollView()
            scrollView.documentView = outlineView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .controlBackgroundColor

            rebuild()
            return scrollView
        }

        func update(controller: ProjectSidebarController) {
            if self.controller !== controller {
                self.controller = controller
                observeWorkspaceChanges()
            }
            if let lastWorkspace,
               ProjectSidebarWorkspaceTree.isEqual(lastWorkspace, controller.workspace) {
                self.lastWorkspace = controller.workspace
                reloadVisibleTerminalRows()
                restoreSelection()
                return
            }
            rebuild()
        }

        private func observeWorkspaceChanges() {
            workspaceObserver = ProjectSidebarWorkspaceChangeObserver(
                publisher: controller.$workspace.eraseToAnyPublisher()
            ) { [weak self] workspace in
                guard let self,
                      lastWorkspace.map({ !ProjectSidebarWorkspaceTree.isEqual($0, workspace) }) ?? true else {
                    return
                }
                rebuild()
            }
        }

        private func rebuild() {
            let editingID = editingNode?.id
            let folders = Node(kind: .section(.folders))
            folders.children = controller.workspace.groups.map { group in
                let node = Node(kind: .group(group))
                node.children = group.projects.map { projectNode($0, groupID: group.id) }
                return node
            }
            let projects = Node(kind: .section(.projects))
            projects.children = controller.workspace.ungroupedProjects.map {
                projectNode($0, groupID: nil)
            }
            roots = [folders, projects]
            foldersSection = folders
            projectsSection = projects
            lastWorkspace = controller.workspace
            editingNode = editingID.flatMap { node(withID: $0) }

            restoringState = true
            outlineView.reloadData()
            outlineView.expandItem(folders)
            outlineView.expandItem(projects)
            for groupNode in folders.children {
                guard case .group(let group) = groupNode.kind else { continue }
                setExpanded(group.isExpanded, node: groupNode)
                restoreProjectExpansion(in: groupNode)
            }
            restoreProjectExpansion(in: projects)
            restoreSelection()
            restoringState = false
        }

        private func projectNode(_ project: ProjectSidebarProject, groupID: UUID?) -> Node {
            let node = Node(kind: .project(project, groupID: groupID))
            node.children = project.terminals.map {
                Node(kind: .terminal($0, projectID: project.id))
            }
            return node
        }

        private func restoreProjectExpansion(in parent: Node) {
            for projectNode in parent.children {
                guard case .project(let project, _) = projectNode.kind else { continue }
                setExpanded(project.isExpanded, node: projectNode)
            }
        }

        private func setExpanded(_ expanded: Bool, node: Node) {
            if expanded { outlineView.expandItem(node) } else { outlineView.collapseItem(node) }
        }

        private func restoreSelection() {
            let wasRestoring = restoringState
            restoringState = true
            defer { restoringState = wasRestoring }
            let selectedID = controller.selectedEntryID ?? controller.selectedProjectID
            guard let selectedID, let node = node(withID: selectedID) else {
                if outlineView.selectedRow >= 0 { outlineView.deselectAll(nil) }
                return
            }
            let row = outlineView.row(forItem: node)
            guard row >= 0, outlineView.selectedRow != row else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        private func reloadVisibleTerminalRows() {
            guard outlineView.numberOfRows > 0 else { return }
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? Node,
                      case .terminal = node.kind,
                      node.id != editingNode?.id else { continue }
                outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }

        private func node(withID id: UUID) -> Node? {
            func find(in nodes: [Node]) -> Node? {
                for node in nodes {
                    if node.id == id { return node }
                    if let found = find(in: node.children) { return found }
                }
                return nil
            }
            return find(in: roots)
        }

        // MARK: Outline data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Node)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? Node)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            switch node.kind {
            case .section, .group: return true
            case .project, .terminal: return !node.children.isEmpty
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node, let drag = node.dragValue else { return nil }
            return ProjectSidebarPasteboard.item(for: drag)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let dragged = draggedItem(from: info),
                  let normalized = normalizeDrop(dragged, proposedItem: item as? Node, childIndex: index),
                  ProjectSidebarDropPlanner.plan(
                    dragging: dragged,
                    onto: normalized.target,
                    in: controller.workspace
                  ) != nil else { return [] }

            outlineView.setDropItem(normalized.parent, dropChildIndex: normalized.childIndex)
            if case .folderURL = dragged { return .copy }
            return .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let dragged = draggedItem(from: info),
                  let normalized = normalizeDrop(dragged, proposedItem: item as? Node, childIndex: index),
                  let plan = ProjectSidebarDropPlanner.plan(
                    dragging: dragged,
                    onto: normalized.target,
                    in: controller.workspace
                  ) else { return false }
            perform(plan)
            return true
        }

        private func draggedItem(from info: NSDraggingInfo) -> ProjectSidebarDraggedItem? {
            let pasteboard = info.draggingPasteboard
            if let value = pasteboard.string(forType: ProjectSidebarPasteboard.folderType),
               let id = UUID(uuidString: value) {
                return .group(id)
            }
            if let value = pasteboard.string(forType: ProjectSidebarPasteboard.projectType),
               let id = UUID(uuidString: value) {
                return .project(id)
            }
            if let value = pasteboard.string(forType: ProjectSidebarPasteboard.terminalType),
               let id = UUID(uuidString: value) {
                return .terminal(id)
            }
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: options)?.first as? URL {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return nil }
                return .folderURL(url)
            }
            return nil
        }

        private func normalizeDrop(
            _ dragged: ProjectSidebarDraggedItem,
            proposedItem: Node?,
            childIndex: Int
        ) -> NormalizedDrop? {
            guard let proposedItem else {
                switch dragged {
                case .group:
                    return NormalizedDrop(
                        target: .folders(index: controller.workspace.groups.count),
                        parent: foldersSection,
                        childIndex: controller.workspace.groups.count
                    )
                case .project, .folderURL:
                    return NormalizedDrop(
                        target: .projects(groupID: nil, index: controller.workspace.ungroupedProjects.count),
                        parent: projectsSection,
                        childIndex: controller.workspace.ungroupedProjects.count
                    )
                case .terminal:
                    return nil
                }
            }

            switch proposedItem.kind {
            case .section(.folders):
                guard case .group = dragged else { return nil }
                let index = bounded(childIndex, count: controller.workspace.groups.count)
                return NormalizedDrop(target: .folders(index: index), parent: proposedItem, childIndex: index)

            case .section(.projects):
                guard case .project = dragged else {
                    guard case .folderURL = dragged else { return nil }
                    let index = bounded(childIndex, count: controller.workspace.ungroupedProjects.count)
                    return NormalizedDrop(
                        target: .projects(groupID: nil, index: index),
                        parent: proposedItem,
                        childIndex: index
                    )
                }
                let index = bounded(childIndex, count: controller.workspace.ungroupedProjects.count)
                return NormalizedDrop(
                    target: .projects(groupID: nil, index: index),
                    parent: proposedItem,
                    childIndex: index
                )

            case .group(let group):
                switch dragged {
                case .group:
                    guard let foldersSection,
                          let index = controller.workspace.groups.firstIndex(where: { $0.id == group.id }) else {
                        return nil
                    }
                    return NormalizedDrop(target: .folders(index: index), parent: foldersSection, childIndex: index)
                case .project, .folderURL:
                    if childIndex == NSOutlineViewDropOnItemIndex {
                        return NormalizedDrop(target: .folder(group.id), parent: proposedItem, childIndex: childIndex)
                    }
                    let index = bounded(childIndex, count: group.projects.count)
                    return NormalizedDrop(
                        target: .projects(groupID: group.id, index: index),
                        parent: proposedItem,
                        childIndex: index
                    )
                case .terminal:
                    return nil
                }

            case .project(let project, let groupID):
                guard case .terminal = dragged else {
                    guard case .project = dragged else {
                        guard case .folderURL = dragged else { return nil }
                        return externalFolderTarget(groupID: groupID)
                    }
                    return projectInsertionTarget(project: project, groupID: groupID)
                }
                let index = childIndex == NSOutlineViewDropOnItemIndex
                    ? project.terminals.count
                    : bounded(childIndex, count: project.terminals.count)
                return NormalizedDrop(
                    target: .terminals(projectID: project.id, index: index),
                    parent: proposedItem,
                    childIndex: index
                )

            case .terminal(let terminal, let projectID):
                guard case .terminal = dragged,
                      let projectNode = node(withID: projectID),
                      case .project(let project, _) = projectNode.kind,
                      let index = project.terminals.firstIndex(where: { $0.id == terminal.id }) else { return nil }
                return NormalizedDrop(
                    target: .terminals(projectID: projectID, index: index),
                    parent: projectNode,
                    childIndex: index
                )
            }
        }

        private func projectInsertionTarget(
            project: ProjectSidebarProject,
            groupID: UUID?
        ) -> NormalizedDrop? {
            let parent: Node?
            let projects: [ProjectSidebarProject]
            if let groupID {
                parent = node(withID: groupID)
                projects = controller.workspace.groups.first(where: { $0.id == groupID })?.projects ?? []
            } else {
                parent = projectsSection
                projects = controller.workspace.ungroupedProjects
            }
            guard let parent, let index = projects.firstIndex(where: { $0.id == project.id }) else { return nil }
            return NormalizedDrop(
                target: .projects(groupID: groupID, index: index),
                parent: parent,
                childIndex: index
            )
        }

        private func externalFolderTarget(groupID: UUID?) -> NormalizedDrop? {
            if let groupID {
                guard let parent = node(withID: groupID),
                      let group = controller.workspace.groups.first(where: { $0.id == groupID }) else { return nil }
                return NormalizedDrop(
                    target: .folder(groupID),
                    parent: parent,
                    childIndex: group.projects.count
                )
            }
            guard let projectsSection else { return nil }
            let index = controller.workspace.ungroupedProjects.count
            return NormalizedDrop(
                target: .projects(groupID: nil, index: index),
                parent: projectsSection,
                childIndex: index
            )
        }

        private func bounded(_ index: Int, count: Int) -> Int {
            index == NSOutlineViewDropOnItemIndex ? count : min(max(index, 0), count)
        }

        private func perform(_ plan: ProjectSidebarDropPlan) {
            switch plan {
            case .moveGroup(let id, let before):
                controller.performSidebarMutation { try controller.moveGroup(id, before: before) }
            case .moveProject(let id, let groupID, let before):
                controller.performSidebarMutation {
                    try controller.moveProject(id, toGroup: groupID, before: before)
                }
            case .moveTerminal(let id, let before):
                controller.performSidebarMutation { try controller.moveTerminal(id, before: before) }
            case .createProject(let url, let groupID):
                controller.createProjectFromDroppedFolder(url, inGroup: groupID)
            }
            rebuild()
        }

        // MARK: Outline delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            if case .section = node.kind { return true }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            if case .section = node.kind { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
            (item as? Node)?.isRenameable == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            guard let node = item as? Node else { return true }
            if case .section = node.kind { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("ProjectSidebarCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCell
                ?? SidebarCell(identifier: identifier)
            cell.configure(node: node, controller: controller)
            cell.titleField.delegate = self
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? Node else { return 24 }
            switch node.kind {
            case .terminal:
                if node.id == editingNode?.id, renameError != nil { return 48 }
                return 26
            case .section: return 24
            case .group, .project:
                return node.id == editingNode?.id && renameError != nil ? 46 : 28
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !restoringState, outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return }
            switch node.kind {
            case .project(let project, _): controller.select(projectID: project.id)
            case .terminal(let terminal, _): controller.select(entryID: terminal.id)
            default: break
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            setExpansion(from: notification, expanded: true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            setExpansion(from: notification, expanded: false)
        }

        private func setExpansion(from notification: Notification, expanded: Bool) {
            guard !restoringState,
                  let node = notification.userInfo?["NSObject"] as? Node,
                  let id = node.id else { return }
            controller.setExpanded(id: id, expanded: expanded)
        }

        // MARK: Rename and menus

        @objc private func beginRenameFromDoubleClick() {
            beginRename(row: outlineView.clickedRow)
        }

        private func beginRenameForSelectedRow() {
            beginRename(row: outlineView.selectedRow)
        }

        private func beginRename(row: Int) {
            guard row >= 0, let node = outlineView.item(atRow: row) as? Node,
                  node.isRenameable,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else {
                return
            }
            editingNode = node
            renameError = nil
            cell.showValidationError(nil)
            cell.prepareForInlineRename()
            DispatchQueue.main.async { [weak self, weak cell] in
                guard let self, let cell, self.editingNode?.id == node.id else { return }
                self.outlineView.editColumn(0, row: row, with: nil, select: true)
                if self.outlineView.window?.firstResponder !== cell.titleField.currentEditor() {
                    self.outlineView.window?.makeFirstResponder(cell.titleField)
                    cell.titleField.selectText(nil)
                }
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let node = editingNode else { return }
            if let rawMovement = obj.userInfo?[NSText.movementUserInfoKey] as? Int,
               NSTextMovement(rawValue: rawMovement) == .cancel {
                finishRename(field: field)
                return
            }
            let name = field.stringValue
            do {
                switch node.kind {
                case .group(let group): try controller.renameGroup(group.id, to: name)
                case .project(let project, _): try controller.renameProject(project.id, to: name)
                case .terminal(let terminal, _): try controller.renameTerminal(terminal.id, to: name)
                case .section: break
                }
                finishRename(field: field)
            } catch {
                renameError = error.localizedDescription
                field.isEditable = true
                field.isSelectable = true
                if let row = row(for: node),
                   let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell {
                    cell.showValidationError(error.localizedDescription)
                    outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                }
                DispatchQueue.main.async { [weak self, weak field] in
                    guard let self, let field else { return }
                    self.outlineView.window?.makeFirstResponder(field)
                    field.selectText(nil)
                }
            }
        }

        private func finishRename(field: NSTextField) {
            field.isEditable = false
            field.isSelectable = false
            editingNode = nil
            renameError = nil
            rebuild()
        }

        private func row(for node: Node) -> Int? {
            let row = outlineView.row(forItem: node)
            return row >= 0 ? row : nil
        }

        private func menu(for node: Node?) -> NSMenu? {
            menuNode = node
            if let node {
                let wasRestoring = restoringState
                restoringState = true
                if let row = row(for: node) {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                restoringState = wasRestoring
            }

            let target: ProjectSidebarContextMenuTarget
            switch node?.kind {
            case .group: target = .folder
            case .project: target = .project
            case .terminal(let terminal, _): target = .terminal(canRetry: controller.launchFailures.contains(terminal.id))
            case .section, nil: target = .background
            }

            let menu = NSMenu()
            for command in ProjectSidebarContextMenu.commands(for: target) {
                if command == .separator {
                    menu.addItem(.separator())
                } else if command == .tag, let node, let item = tagMenuItem(for: node) {
                    menu.addItem(item)
                } else if let title = command.title {
                    menu.addItem(item(title, selector(for: command)))
                }
            }
            return menu
        }

        private func selector(for command: ProjectSidebarMenuCommand) -> Selector {
            switch command {
            case .addFolder: #selector(addFolder)
            case .addProject: #selector(addProject)
            case .newTerminal: #selector(addTerminal)
            case .rename: #selector(renameMenuItem)
            case .tag: #selector(setColorTag(_:))
            case .retry: #selector(retryTerminal)
            case .changeFolder: #selector(replaceTerminalFolder)
            case .removeFolder, .removeProject, .removeTerminal: #selector(removeMenuItem)
            case .separator: fatalError("Separators do not have actions")
            }
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        private func tagMenuItem(for node: Node) -> NSMenuItem? {
            let selectedTag: ProjectSidebarColorTag?
            switch node.kind {
            case .group(let group): selectedTag = group.colorTag
            case .project(let project, _): selectedTag = project.colorTag
            case .section, .terminal: return nil
            }

            let menu = NSMenu(title: "Tags")
            let noTag = item("No Tag", #selector(setColorTag(_:)))
            noTag.representedObject = ""
            noTag.state = selectedTag == nil ? .on : .off
            menu.addItem(noTag)
            menu.addItem(.separator())

            for tag in ProjectSidebarColorTag.allCases {
                let tagItem = item(tag.label, #selector(setColorTag(_:)))
                tagItem.representedObject = tag.rawValue
                tagItem.image = tag.swatchImage()
                tagItem.state = selectedTag == tag ? .on : .off
                tagItem.setAccessibilityLabel("\(tag.label) tag")
                menu.addItem(tagItem)
            }

            let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }

        @objc private func addFolder() {
            controller.performSidebarMutation { _ = try controller.createGroup() }
        }

        @objc private func addProject() {
            if case .group(let group)? = menuNode?.kind {
                controller.createProjectFromFolderPicker(inGroup: group.id)
            } else {
                controller.createProjectFromFolderPicker()
            }
        }

        @objc private func addTerminal() {
            guard case .project(let project, _)? = menuNode?.kind else { return }
            controller.performSidebarMutation { _ = try controller.createTerminal(in: project.id) }
        }

        @objc private func renameMenuItem() {
            guard let menuNode else { return }
            beginRename(row: outlineView.row(forItem: menuNode))
        }

        @objc private func setColorTag(_ sender: NSMenuItem) {
            guard let menuNode, let rawValue = sender.representedObject as? String else { return }
            let colorTag = ProjectSidebarColorTag(rawValue: rawValue)
            switch menuNode.kind {
            case .group(let group):
                controller.performSidebarMutation {
                    try controller.setGroupColorTag(group.id, to: colorTag)
                }
            case .project(let project, _):
                controller.performSidebarMutation {
                    try controller.setProjectColorTag(project.id, to: colorTag)
                }
            case .section, .terminal:
                return
            }
        }

        @objc private func removeMenuItem() { remove(node: menuNode) }

        private func deleteSelectedRow() {
            guard outlineView.selectedRow >= 0 else { return }
            remove(node: outlineView.item(atRow: outlineView.selectedRow) as? Node)
        }

        private func remove(node: Node?) {
            guard let node else { return }
            let previousWorkspace = controller.workspace
            switch node.kind {
            case .group(let group):
                controller.performSidebarMutation { try controller.deleteGroup(group.id) }
            case .project(let project, _):
                _ = controller.deleteProject(project.id)
            case .terminal(let terminal, _):
                _ = controller.deleteTerminal(terminal.id)
            case .section:
                return
            }
            if controller.workspace != previousWorkspace { rebuild() }
        }

        @objc private func retryTerminal() {
            guard case .terminal(let terminal, _)? = menuNode?.kind else { return }
            _ = controller.launch(entryID: terminal.id)
        }

        @objc private func replaceTerminalFolder() {
            guard case .terminal(let terminal, _)? = menuNode?.kind else { return }
            controller.chooseReplacementFolder(forEntry: terminal.id)
        }
    }
}

private final class NativeOutlineView: NSOutlineView {
    var menuProvider: ((Node?) -> NSMenu?)?
    var renameAction: (() -> Void)?
    var deleteAction: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let node = row >= 0 ? item(atRow: row) as? Node : nil
        return menuProvider?(node)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            renameAction?()
        case 51, 117:
            deleteAction?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class ProjectSidebarScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let outlineView = documentView as? NSOutlineView else { return }
        let width = contentSize.width
        if let column = outlineView.tableColumns.first, abs(column.width - width) >= 0.5 {
            column.width = width
        }
        if abs(outlineView.frame.width - width) >= 0.5 {
            outlineView.setFrameSize(NSSize(width: width, height: max(outlineView.frame.height, contentSize.height)))
        }
    }
}

private extension ProjectSidebarColorTag {
    var color: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    func swatchImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = rect.insetBy(dx: 1, dy: 1)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(ovalIn: circle)
            border.lineWidth = 1
            border.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

final class SidebarCell: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    private let validationField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let tagIndicator = NSImageView()
    private let attentionIndicator = NSImageView()
    private var attentionWidthConstraint: NSLayoutConstraint!
    private var labelsLeadingConstraint: NSLayoutConstraint!
    private var taggedLabelsLeadingConstraint: NSLayoutConstraint!
    private var usesSecondaryTitleColor = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTitleColor() }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        attentionWidthConstraint = attentionIndicator.widthAnchor.constraint(equalToConstant: 0)
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        tagIndicator.translatesAutoresizingMaskIntoConstraints = false
        tagIndicator.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        tagIndicator.isHidden = true
        tagIndicator.setAccessibilityElement(false)
        attentionIndicator.translatesAutoresizingMaskIntoConstraints = false
        attentionIndicator.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        attentionIndicator.contentTintColor = .systemOrange
        attentionIndicator.isHidden = true
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        validationField.translatesAutoresizingMaskIntoConstraints = false
        validationField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationField.textColor = .systemRed
        validationField.lineBreakMode = .byTruncatingTail
        validationField.usesSingleLineMode = true
        validationField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        validationField.isHidden = true

        let labels = NSStackView(views: [titleField, validationField])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0
        labels.setHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(tagIndicator)
        addSubview(labels)
        addSubview(attentionIndicator)
        imageView = iconView
        textField = titleField
        labelsLeadingConstraint = labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6)
        taggedLabelsLeadingConstraint = labels.leadingAnchor.constraint(
            equalTo: tagIndicator.trailingAnchor,
            constant: 6
        )
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            tagIndicator.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            tagIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagIndicator.widthAnchor.constraint(equalToConstant: 12),
            tagIndicator.heightAnchor.constraint(equalToConstant: 12),
            labelsLeadingConstraint,
            labels.trailingAnchor.constraint(equalTo: attentionIndicator.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.widthAnchor.constraint(equalTo: labels.widthAnchor),
            validationField.widthAnchor.constraint(equalTo: labels.widthAnchor),
            attentionIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            attentionIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            attentionWidthConstraint,
            attentionIndicator.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    fileprivate func configure(node: Node, controller: ProjectSidebarController) {
        titleField.isEditable = false
        titleField.isSelectable = false
        showValidationError(nil)
        setAttention(.none)
        setColorTag(nil)
        iconView.toolTip = nil

        switch node.kind {
        case .section(let section):
            titleField.stringValue = section.title
            titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            usesSecondaryTitleColor = true
            updateTitleColor()
            iconView.image = nil
        case .group(let group):
            titleField.stringValue = group.name
            standardTitle()
            iconView.contentTintColor = .secondaryLabelColor
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
            setColorTag(group.colorTag)
        case .project(let project, _):
            titleField.stringValue = project.name
            standardTitle()
            iconView.contentTintColor = .secondaryLabelColor
            iconView.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Project")
            setColorTag(project.colorTag)
        case .terminal(let terminal, _):
            titleField.stringValue = terminal.name
            standardTitle()
            let status = controller.entryStatus(terminal.id)
            iconView.contentTintColor = status == .running ? .systemGreen : .secondaryLabelColor
            iconView.image = NSImage(systemSymbolName: status.systemImage, accessibilityDescription: status.label)
            iconView.toolTip = status.helpText
            setAttention(controller.runtime(for: terminal.id)?.attention ?? .none)
        }
    }

    private func setAttention(_ attention: ProjectSidebarEntryAttention) {
        attentionIndicator.isHidden = attention == .none
        attentionWidthConstraint.constant = attention == .none ? 0 : 14
        attentionIndicator.image = switch attention {
        case .none:
            nil
        case .needsAttention:
            NSImage(
                systemSymbolName: "bell.badge.fill",
                accessibilityDescription: attention.accessibilityLabel
            )
        }
    }

    private func setColorTag(_ colorTag: ProjectSidebarColorTag?) {
        tagIndicator.isHidden = colorTag == nil
        tagIndicator.setAccessibilityElement(colorTag != nil)

        guard let colorTag else {
            tagIndicator.setAccessibilityLabel(nil)
            tagIndicator.image = nil
            tagIndicator.toolTip = nil
            taggedLabelsLeadingConstraint.isActive = false
            labelsLeadingConstraint.isActive = true
            return
        }

        labelsLeadingConstraint.isActive = false
        taggedLabelsLeadingConstraint.isActive = true
        tagIndicator.image = NSImage(
            systemSymbolName: colorTag.systemImage,
            accessibilityDescription: colorTag.accessibilityLabel
        )
        tagIndicator.contentTintColor = colorTag.color
        tagIndicator.toolTip = colorTag.accessibilityLabel
        tagIndicator.setAccessibilityLabel(colorTag.accessibilityLabel)
    }

    func showValidationError(_ message: String?) {
        validationField.stringValue = message ?? ""
        validationField.isHidden = message == nil
    }

    func prepareForInlineRename() {
        titleField.isEditable = true
        titleField.isSelectable = true
    }

    private func standardTitle() {
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        usesSecondaryTitleColor = false
        updateTitleColor()
    }

    private func updateTitleColor() {
        if backgroundStyle == .emphasized {
            titleField.textColor = .alternateSelectedControlTextColor
        } else {
            titleField.textColor = usesSecondaryTitleColor ? .secondaryLabelColor : .labelColor
        }
    }
}

private final class Node: NSObject {
    let kind: Kind
    var children: [Node] = []

    init(kind: Kind) { self.kind = kind }

    var id: UUID? {
        switch kind {
        case .group(let group): group.id
        case .project(let project, _): project.id
        case .terminal(let terminal, _): terminal.id
        case .section: nil
        }
    }

    var dragValue: ProjectSidebarDraggedItem? {
        switch kind {
        case .group(let group): .group(group.id)
        case .project(let project, _): .project(project.id)
        case .terminal(let terminal, _): .terminal(terminal.id)
        case .section: nil
        }
    }

    var isRenameable: Bool {
        if case .section = kind { return false }
        return true
    }

    enum Kind {
        case section(Section)
        case group(ProjectSidebarGroup)
        case project(ProjectSidebarProject, groupID: UUID?)
        case terminal(ProjectSidebarTerminal, projectID: UUID)
    }
}

private enum Section {
    case folders
    case projects

    var title: String {
        switch self {
        case .folders: "Folders"
        case .projects: "Projects"
        }
    }
}

private struct NormalizedDrop {
    let target: ProjectSidebarDropTarget
    let parent: Node?
    let childIndex: Int
}
