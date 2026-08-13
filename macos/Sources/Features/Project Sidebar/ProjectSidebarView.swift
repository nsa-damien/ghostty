import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebarView: View {
    @ObservedObject var controller: ProjectSidebarController

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: ProjectSidebarWorkspaceValidator.minimumSidebarWidth,
                       idealWidth: controller.workspace.sidebarWidth,
                       maxWidth: ProjectSidebarWorkspaceValidator.maximumSidebarWidth)
            detail
                .frame(minWidth: 420)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            if !controller.workspace.projects.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: controller.performNewTerminal) {
                        Label("New Terminal", systemImage: "plus")
                    }
                    .keyboardShortcut("t", modifiers: [.command])
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
                if controller.workspace.projects.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("Organize your terminals into projects")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Each project keeps named terminals and their launch folders together.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Create Project", action: controller.createProjectFromFolderPicker)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(controller.workspace.projects) { project in
                            ProjectSidebarProjectRow(controller: controller, project: project)
                        }
                        .onMove { offsets, destination in
                            guard let source = offsets.first else { return }
                            try? controller.reorderProjects(from: source, to: destination)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
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

    @ViewBuilder
    private var detail: some View {
        if let entryID = controller.selectedEntryID,
           let runtime = controller.runtime(for: entryID) {
            TerminalView(ghostty: controller.ghostty, viewModel: runtime.controller, delegate: runtime.controller)
                .id(entryID)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Select a terminal to start")
                    .font(.headline)
                Text("Your saved projects remain here after Ghostty restarts.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProjectSidebarProjectRow: View {
    @ObservedObject var controller: ProjectSidebarController
    let project: ProjectSidebarProject
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var validationError: String?

    var body: some View {
        DisclosureGroup(isExpanded: binding(for: project.id)) {
            ForEach(project.ungroupedEntries) { entry in
                ProjectSidebarEntryRow(controller: controller, entry: entry)
            }
            .onMove { offsets, destination in
                guard let source = offsets.first else { return }
                try? controller.reorderTerminals(in: project.id, groupID: nil, from: source, to: destination)
            }
            ForEach(project.groups) { group in
                DisclosureGroup(isExpanded: binding(for: group.id)) {
                    ForEach(group.entries) { entry in
                        ProjectSidebarEntryRow(controller: controller, entry: entry)
                    }
                    .onMove { offsets, destination in
                        guard let source = offsets.first else { return }
                        try? controller.reorderTerminals(in: project.id, groupID: group.id, from: source, to: destination)
                    }
                } label: {
                    ProjectSidebarGroupLabel(controller: controller, projectID: project.id, group: group)
                }
                .contextMenu {
                    Button("Delete Group", role: .destructive) {
                        try? controller.deleteGroup(group.id, in: project.id)
                    }
                }
            }
            .onMove { offsets, destination in
                guard let source = offsets.first else { return }
                try? controller.reorderGroups(in: project.id, from: source, to: destination)
            }
        } label: {
            HStack {
                if isEditingName {
                    TextField("Project name", text: $draftName)
                        .onSubmit { commitName() }
                        .onExitCommand { isEditingName = false }
                } else {
                    Button {
                        controller.select(projectID: project.id)
                    } label: {
                        Label(project.name, systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .onTapGesture(count: 2) {
                        draftName = project.name
                        isEditingName = true
                    }
                }
            }
            if let validationError {
                Text(validationError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .contextMenu {
            Button("New Terminal") {
                do { _ = try controller.createTerminal(in: project.id) } catch { }
            }
            Button("New Group") {
                do { _ = try controller.createGroup(in: project.id, name: "Group \(project.groups.count + 1)") } catch { }
            }
            Button("Rename") {
                draftName = project.name
                isEditingName = true
            }
            Button("Replace Base Folder") {
                controller.chooseReplacementFolder(forProject: project.id)
            }
            Divider()
            Button("Delete Project", role: .destructive) {
                _ = controller.deleteProject(project.id)
            }
        }
        .onDrop(of: [.text], delegate: ProjectSidebarEntryDropDelegate(
            controller: controller,
            projectID: project.id,
            groupID: nil
        ))
    }

    private func commitName() {
        do {
            try controller.renameProject(project.id, to: draftName)
            validationError = nil
            isEditingName = false
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                if id == project.id { return project.isExpanded }
                return project.groups.first(where: { $0.id == id })?.isExpanded ?? true
            },
            set: { newValue in
                controller.setExpanded(id: id, expanded: newValue)
            }
        )
    }
}

private struct ProjectSidebarGroupLabel: View {
    @ObservedObject var controller: ProjectSidebarController
    let projectID: UUID
    let group: ProjectSidebarGroup
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var validationError: String?

    var body: some View {
        HStack {
            if isEditingName {
                TextField("Group name", text: $draftName)
                    .onSubmit { commitName() }
                    .onExitCommand { isEditingName = false }
            } else {
                Text(group.name)
                    .onTapGesture(count: 2) {
                        draftName = group.name
                        isEditingName = true
                    }
            }
            if let validationError {
                Text(validationError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onDrop(of: [.text], delegate: ProjectSidebarEntryDropDelegate(
            controller: controller,
            projectID: projectID,
            groupID: group.id
        ))
        .contextMenu {
            Button("Rename") {
                draftName = group.name
                isEditingName = true
            }
            Button("Delete Group", role: .destructive) {
                try? controller.deleteGroup(group.id, in: projectID)
            }
        }
    }

    private func commitName() {
        do {
            try controller.renameGroup(group.id, in: projectID, to: draftName)
            validationError = nil
            isEditingName = false
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct ProjectSidebarEntryRow: View {
    @ObservedObject var controller: ProjectSidebarController
    let entry: ProjectSidebarTerminal
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var validationError: String?

    var body: some View {
        Button {
            controller.select(entryID: entry.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: controller.entryStatus(entry.id).systemImage)
                    .foregroundStyle(controller.entryStatus(entry.id) == .running ? .green : .secondary)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    if isEditingName {
                        TextField("Terminal name", text: $draftName)
                            .onSubmit { commitName() }
                            .onExitCommand { isEditingName = false }
                    } else {
                        Text(entry.name)
                            .onTapGesture(count: 2) {
                                draftName = entry.name
                                isEditingName = true
                            }
                    }
                    if let validationError {
                        Text(validationError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    if let runtime = controller.runtime(for: entry.id),
                       let focused = runtime.controller.focusedSurface,
                       !focused.title.isEmpty {
                        Text(focused.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(controller.entryStatus(entry.id).label)
        .onDrag {
            NSItemProvider(object: entry.id.uuidString as NSString)
        }
        .contextMenu {
            Button("Rename") {
                draftName = entry.name
                isEditingName = true
            }
            if controller.launchFailures.contains(entry.id) {
                Button("Retry") { _ = controller.launch(entryID: entry.id) }
            }
            Button("Change Folder") {
                controller.chooseReplacementFolder(forEntry: entry.id)
            }
            Divider()
            Button("Delete Terminal", role: .destructive) {
                _ = controller.deleteTerminal(entry.id)
            }
        }
    }

    private func commitName() {
        do {
            try controller.renameTerminal(entry.id, to: draftName)
            validationError = nil
            isEditingName = false
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct ProjectSidebarEntryDropDelegate: DropDelegate {
    let controller: ProjectSidebarController
    let projectID: UUID
    let groupID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            let string: String? = if let data = item as? Data {
                String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                string
            } else if let string = item as? NSString {
                string as String
            } else {
                nil
            }
            DispatchQueue.main.async {
                guard let string, let entryID = UUID(uuidString: string),
                      let location = controller.location(of: entryID),
                      location.projectID == projectID else { return }
                try? controller.moveTerminal(entryID, toGroup: groupID)
            }
        }
        return true
    }
}
