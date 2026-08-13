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
            ZStack {
                ProjectSidebarOutlineView(controller: controller)

                if controller.workspace.projects.isEmpty && controller.workspace.groups.isEmpty {
                    emptyState
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 360)
        .onDrop(of: [.fileURL], delegate: ProjectSidebarEmptyStateDropDelegate(controller: controller))
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

private struct ProjectSidebarEmptyStateDropDelegate: DropDelegate {
    let controller: ProjectSidebarController

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
                controller.createProjectFromDroppedFolder(url)
            }
        }
        return true
    }
}
