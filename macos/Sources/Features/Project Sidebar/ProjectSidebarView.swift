import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebarView: View {
    @ObservedObject var controller: ProjectSidebarController

    var body: some View {
        HSplitView {
            sidebar
                .frame(
                    minWidth: ProjectSidebarWorkspaceValidator.minimumSidebarWidth,
                    idealWidth: controller.workspace.sidebarWidth,
                    maxWidth: ProjectSidebarWorkspaceValidator.maximumSidebarWidth
                )
            detail.frame(minWidth: 420)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Terminal", action: controller.performNewTerminal)
                        .keyboardShortcut("t", modifiers: [.command])
                    Button("New Project") { controller.createProjectFromFolderPicker() }
                    Button("New Folder") {
                        controller.performSidebarMutation { _ = try controller.createGroup() }
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button {
                    controller.setSidebarVisible(!controller.workspace.sidebarVisible)
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if controller.workspace.sidebarVisible {
            VStack(spacing: 0) {
                if controller.workspace.projects.isEmpty && controller.workspace.groups.isEmpty {
                    emptyState
                } else {
                    List {
                        if !controller.workspace.groups.isEmpty {
                            Section {
                                ForEach(controller.workspace.groups) { group in
                                    ProjectSidebarFolderRow(controller: controller, group: group)
                                }
                                .onMove { offsets, destination in
                                    guard let source = offsets.first else { return }
                                    controller.performSidebarMutation {
                                        try controller.reorderGroups(from: source, to: destination)
                                    }
                                }
                            } header: {
                                Text("Folders")
                            }
                        }

                        if !controller.workspace.groups.isEmpty ||
                            !controller.workspace.ungroupedProjects.isEmpty {
                            Section {
                                if controller.workspace.ungroupedProjects.isEmpty {
                                    Text("Drop projects here")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    ForEach(controller.workspace.ungroupedProjects) { project in
                                        ProjectSidebarProjectRow(
                                            controller: controller,
                                            project: project,
                                            groupID: nil
                                        )
                                    }
                                    .onMove { offsets, destination in
                                        guard let source = offsets.first else { return }
                                        controller.performSidebarMutation {
                                            try controller.reorderProjects(
                                                inGroup: nil,
                                                from: source,
                                                to: destination
                                            )
                                        }
                                    }
                                }
                            } header: {
                                Text("Projects")
                                    .onDrop(
                                        of: [ProjectSidebarDragPayload.projectType],
                                        delegate: ProjectSidebarProjectDropDelegate(
                                            controller: controller,
                                            groupID: nil,
                                            beforeProjectID: nil
                                        )
                                    )
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .onDrop(
                of: [.fileURL],
                delegate: ProjectSidebarExternalFolderDropDelegate(
                    controller: controller,
                    groupID: nil
                )
            )
            .overlay(alignment: .bottom) {
                if let notice = controller.recoveryNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.thinMaterial)
                }
            }
        } else {
            Color.clear
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Organize repositories into projects")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Create a folder for related projects, or add a project directly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("You can also drop a repository folder here from Finder.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Button("New Folder") {
                    controller.performSidebarMutation { _ = try controller.createGroup() }
                }
                Button("Create Project") { controller.createProjectFromFolderPicker() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        if let entryID = controller.selectedEntryID,
           let runtime = controller.runtime(for: entryID) {
            TerminalView(
                ghostty: controller.ghostty,
                viewModel: runtime.controller,
                delegate: runtime.controller
            )
            .id(entryID)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Select a terminal to start").font(.headline)
                Text("Your saved projects remain here after Ghostty restarts.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProjectSidebarFolderRow: View {
    @ObservedObject var controller: ProjectSidebarController
    let group: ProjectSidebarGroup
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var validationError: String?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            ForEach(group.projects) { project in
                ProjectSidebarProjectRow(
                    controller: controller,
                    project: project,
                    groupID: group.id
                )
            }
            .onMove { offsets, destination in
                guard let source = offsets.first else { return }
                controller.performSidebarMutation {
                    try controller.reorderProjects(inGroup: group.id, from: source, to: destination)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                editableName
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Add Project") { controller.createProjectFromFolderPicker(inGroup: group.id) }
                Button("Rename") { beginEditing() }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    controller.performSidebarMutation { try controller.deleteGroup(group.id) }
                }
            }
            .onDrag { ProjectSidebarDragPayload.provider(forGroup: group.id) }
            .onDrop(
                of: [ProjectSidebarDragPayload.groupType, ProjectSidebarDragPayload.projectType],
                delegate: ProjectSidebarFolderDropDelegate(
                    controller: controller,
                    destinationGroupID: group.id
                )
            )
            .onDrop(
                of: [.fileURL],
                delegate: ProjectSidebarExternalFolderDropDelegate(
                    controller: controller,
                    groupID: group.id
                )
            )
        }
    }

    @ViewBuilder
    private var editableName: some View {
        if isEditingName {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Folder name", text: $draftName)
                    .focused($nameIsFocused)
                    .onAppear { nameIsFocused = true }
                    .onSubmit { commitName() }
                    .onExitCommand { cancelEditing() }
                if let validationError {
                    Text(validationError).font(.caption2).foregroundStyle(.red)
                }
            }
        } else {
            Text(group.name)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    private var expanded: Binding<Bool> {
        Binding(
            get: { group.isExpanded },
            set: { controller.setExpanded(id: group.id, expanded: $0) }
        )
    }

    private func beginEditing() {
        draftName = group.name
        validationError = nil
        isEditingName = true
    }

    private func cancelEditing() {
        validationError = nil
        isEditingName = false
    }

    private func commitName() {
        do {
            try controller.renameGroup(group.id, to: draftName)
            cancelEditing()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct ProjectSidebarProjectRow: View {
    @ObservedObject var controller: ProjectSidebarController
    let project: ProjectSidebarProject
    let groupID: UUID?
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var validationError: String?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        DisclosureGroup(isExpanded: expanded) {
            ForEach(project.terminals) { terminal in
                ProjectSidebarEntryRow(
                    controller: controller,
                    entry: terminal,
                    projectID: project.id
                )
            }
            .onMove { offsets, destination in
                guard let source = offsets.first else { return }
                controller.performSidebarMutation {
                    try controller.reorderTerminals(in: project.id, from: source, to: destination)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                editableName
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.select(projectID: project.id) }
            .contextMenu {
                Button("New Terminal") { _ = try? controller.createTerminal(in: project.id) }
                Button("Rename") { beginEditing() }
                Button("Replace Base Folder") { controller.chooseReplacementFolder(forProject: project.id) }
                if groupID != nil {
                    Button("Move Out of Folder") {
                        controller.performSidebarMutation {
                            try controller.moveProject(project.id, toGroup: nil)
                        }
                    }
                }
                Divider()
                Button("Delete Project", role: .destructive) { _ = controller.deleteProject(project.id) }
            }
            .onDrag { ProjectSidebarDragPayload.provider(forProject: project.id) }
            .onDrop(
                of: [ProjectSidebarDragPayload.projectType, ProjectSidebarDragPayload.terminalType],
                delegate: ProjectSidebarCombinedDropDelegate(
                    controller: controller,
                    projectID: project.id,
                    groupID: groupID
                )
            )
        }
    }

    @ViewBuilder
    private var editableName: some View {
        if isEditingName {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Project name", text: $draftName)
                    .focused($nameIsFocused)
                    .onAppear { nameIsFocused = true }
                    .onSubmit { commitName() }
                    .onExitCommand { cancelEditing() }
                if let validationError {
                    Text(validationError).font(.caption2).foregroundStyle(.red)
                }
            }
        } else {
            Text(project.name)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    private var expanded: Binding<Bool> {
        Binding(
            get: { project.isExpanded },
            set: { controller.setExpanded(id: project.id, expanded: $0) }
        )
    }

    private func beginEditing() {
        draftName = project.name
        validationError = nil
        isEditingName = true
    }

    private func cancelEditing() {
        validationError = nil
        isEditingName = false
    }

    private func commitName() {
        do {
            try controller.renameProject(project.id, to: draftName)
            cancelEditing()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct ProjectSidebarEntryRow: View {
    @ObservedObject var controller: ProjectSidebarController
    let entry: ProjectSidebarTerminal
    let projectID: UUID
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var validationError: String?
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { controller.select(entryID: entry.id) } label: {
                Image(systemName: controller.entryStatus(entry.id).systemImage)
                    .foregroundStyle(controller.entryStatus(entry.id) == .running ? .green : .secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                editableName
                if let runtime = controller.runtime(for: entry.id),
                   let focused = runtime.controller.focusedSurface,
                   !focused.title.isEmpty {
                    Text(focused.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.select(entryID: entry.id) }
        .accessibilityValue(controller.entryStatus(entry.id).label)
        .onDrag { ProjectSidebarDragPayload.provider(forTerminal: entry.id) }
        .onDrop(
            of: [ProjectSidebarDragPayload.terminalType],
            delegate: ProjectSidebarTerminalDropDelegate(
                controller: controller,
                projectID: projectID,
                beforeTerminalID: entry.id
            )
        )
        .contextMenu {
            Button("Rename") { beginEditing() }
            if controller.launchFailures.contains(entry.id) {
                Button("Retry") { _ = controller.launch(entryID: entry.id) }
            }
            Button("Change Folder") { controller.chooseReplacementFolder(forEntry: entry.id) }
            Divider()
            Button("Delete Terminal", role: .destructive) { _ = controller.deleteTerminal(entry.id) }
        }
    }

    @ViewBuilder
    private var editableName: some View {
        if isEditingName {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Terminal name", text: $draftName)
                    .focused($nameIsFocused)
                    .onAppear { nameIsFocused = true }
                    .onSubmit { commitName() }
                    .onExitCommand { cancelEditing() }
                if let validationError {
                    Text(validationError).font(.caption2).foregroundStyle(.red)
                }
            }
        } else {
            Text(entry.name)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
        }
    }

    private func beginEditing() {
        controller.select(entryID: entry.id)
        draftName = entry.name
        validationError = nil
        isEditingName = true
    }

    private func cancelEditing() {
        validationError = nil
        isEditingName = false
    }

    private func commitName() {
        do {
            try controller.renameTerminal(entry.id, to: draftName)
            cancelEditing()
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private enum ProjectSidebarDragPayload {
    static let groupType = UTType(exportedAs: "com.mitchellh.ghostty.project-sidebar.folder")
    static let projectType = UTType(exportedAs: "com.mitchellh.ghostty.project-sidebar.project")
    static let terminalType = UTType(exportedAs: "com.mitchellh.ghostty.project-sidebar.terminal")

    static func provider(forGroup id: UUID) -> NSItemProvider {
        provider(for: id, type: groupType)
    }

    static func provider(forProject id: UUID) -> NSItemProvider {
        provider(for: id, type: projectType)
    }

    static func provider(forTerminal id: UUID) -> NSItemProvider {
        provider(for: id, type: terminalType)
    }

    static func loadID(
        from info: DropInfo,
        type: UTType,
        completion: @escaping (UUID?) -> Void
    ) -> Bool {
        guard let provider = info.itemProviders(for: [type]).first else { return false }
        provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
            let value: String? = if let data = item as? Data {
                String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                string
            } else if let string = item as? NSString {
                string as String
            } else {
                nil
            }
            DispatchQueue.main.async { completion(value.flatMap(UUID.init(uuidString:))) }
        }
        return true
    }

    private static func provider(for id: UUID, type: UTType) -> NSItemProvider {
        NSItemProvider(item: id.uuidString as NSString, typeIdentifier: type.identifier)
    }
}

private struct ProjectSidebarFolderDropDelegate: DropDelegate {
    let controller: ProjectSidebarController
    let destinationGroupID: UUID

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [ProjectSidebarDragPayload.groupType]) ||
            info.hasItemsConforming(to: [ProjectSidebarDragPayload.projectType])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [ProjectSidebarDragPayload.groupType]) {
            let after = info.location.y > 12
            return ProjectSidebarDragPayload.loadID(
                from: info,
                type: ProjectSidebarDragPayload.groupType
            ) { groupID in
                guard let groupID else { return }
                controller.performSidebarMutation {
                    try controller.moveGroup(
                        groupID,
                        relativeTo: destinationGroupID,
                        after: after
                    )
                }
            }
        }
        return ProjectSidebarDragPayload.loadID(
            from: info,
            type: ProjectSidebarDragPayload.projectType
        ) { projectID in
            guard let projectID else { return }
            controller.performSidebarMutation {
                try controller.moveProject(projectID, toGroup: destinationGroupID)
            }
        }
    }
}

private struct ProjectSidebarProjectDropDelegate: DropDelegate {
    let controller: ProjectSidebarController
    let groupID: UUID?
    let beforeProjectID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [ProjectSidebarDragPayload.projectType])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        ProjectSidebarDragPayload.loadID(
            from: info,
            type: ProjectSidebarDragPayload.projectType
        ) { projectID in
            guard let projectID else { return }
            controller.performSidebarMutation {
                try controller.moveProject(projectID, toGroup: groupID, before: beforeProjectID)
            }
        }
    }
}

private struct ProjectSidebarTerminalDropDelegate: DropDelegate {
    let controller: ProjectSidebarController
    let projectID: UUID
    let beforeTerminalID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [ProjectSidebarDragPayload.terminalType])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        ProjectSidebarDragPayload.loadID(
            from: info,
            type: ProjectSidebarDragPayload.terminalType
        ) { terminalID in
            guard let terminalID,
                  controller.location(of: terminalID)?.projectID == projectID else { return }
            controller.performSidebarMutation {
                try controller.moveTerminal(terminalID, before: beforeTerminalID)
            }
        }
    }
}

private struct ProjectSidebarCombinedDropDelegate: DropDelegate {
    let controller: ProjectSidebarController
    let projectID: UUID
    let groupID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [ProjectSidebarDragPayload.projectType]) ||
            info.hasItemsConforming(to: [ProjectSidebarDragPayload.terminalType])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [ProjectSidebarDragPayload.projectType]) {
            let after = info.location.y > 12
            return ProjectSidebarDragPayload.loadID(
                from: info,
                type: ProjectSidebarDragPayload.projectType
            ) { draggedProjectID in
                guard let draggedProjectID else { return }
                controller.performSidebarMutation {
                    try controller.moveProject(
                        draggedProjectID,
                        toGroup: groupID,
                        relativeTo: projectID,
                        after: after
                    )
                }
            }
        }
        return ProjectSidebarDragPayload.loadID(
            from: info,
            type: ProjectSidebarDragPayload.terminalType
        ) { terminalID in
            guard let terminalID,
                  controller.location(of: terminalID)?.projectID == projectID else { return }
            controller.performSidebarMutation {
                try controller.moveTerminal(terminalID, before: nil)
            }
        }
    }
}

private struct ProjectSidebarExternalFolderDropDelegate: DropDelegate {
    let controller: ProjectSidebarController
    let groupID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
            guard let url = object as? URL else { return }
            DispatchQueue.main.async {
                controller.createProjectFromDroppedFolder(url, inGroup: groupID)
            }
        }
        return true
    }
}
