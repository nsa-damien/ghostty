import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ProjectSidebarWidthPersistence {
    static func updatedWidth(current: Double, measured: Double) -> Double? {
        let rounded = measured.rounded()
        let bounded = min(
            ProjectSidebarWorkspaceValidator.maximumSidebarWidth,
            max(ProjectSidebarWorkspaceValidator.minimumSidebarWidth, rounded)
        )
        return abs(bounded - current) >= 1 ? bounded : nil
    }
}

struct ProjectSidebarView: View {
    @ObservedObject var controller: ProjectSidebarController

    var body: some View {
        ProjectSidebarSplitView(controller: controller)
        .frame(minWidth: 760, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ProjectSidebarToolbarMenu.commands, id: \.self) { command in
                        switch command {
                        case .addProject:
                            Button(command.title ?? "Add Project") {
                                controller.createProjectFromFolderPicker()
                            }
                        case .addFolder:
                            Button(command.title ?? "Add Folder") {
                                controller.performSidebarMutation { _ = try controller.createGroup() }
                            }
                        default:
                            EmptyView()
                        }
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
}

enum ProjectSidebarToolbarMenu {
    static let commands: [ProjectSidebarMenuCommand] = [.addProject, .addFolder]
}

enum ProjectSidebarHostingUpdate {
    static func shouldReplaceController(current: AnyObject, next: AnyObject) -> Bool {
        current !== next
    }
}

struct ProjectSidebarSplitView: NSViewRepresentable {
    let controller: ProjectSidebarController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> ProjectSidebarNativeSplitView {
        context.coordinator.makeSplitView()
    }

    func updateNSView(_ splitView: ProjectSidebarNativeSplitView, context: Context) {
        context.coordinator.update(controller: controller)
    }

    final class Coordinator: NSObject {
        private var controller: ProjectSidebarController
        private var splitView: ProjectSidebarNativeSplitView?
        private var sidebarHost: NSHostingView<ProjectSidebarSidebarContent>?
        private var detailHost: NSHostingView<ProjectSidebarDetailContent>?
        private let widthCoordinator = ProjectSidebarSplitWidthCoordinator()

        init(controller: ProjectSidebarController) {
            self.controller = controller
        }

        func makeSplitView() -> ProjectSidebarNativeSplitView {
            let splitView = ProjectSidebarNativeSplitView()
            splitView.isVertical = true
            splitView.dividerStyle = .thin
            splitView.delegate = widthCoordinator
            splitView.sidebarWidthDidChangeByUser = { [weak self] width in
                self?.controller.setSidebarWidth(width)
            }

            let sidebarHost = NSHostingView(rootView: ProjectSidebarSidebarContent(controller: controller))
            let detailHost = NSHostingView(rootView: ProjectSidebarDetailContent(controller: controller))
            splitView.addArrangedSubview(sidebarHost)
            splitView.addArrangedSubview(detailHost)
            splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

            self.splitView = splitView
            self.sidebarHost = sidebarHost
            self.detailHost = detailHost

            DispatchQueue.main.async { [weak self, weak splitView] in
                guard let self, let splitView else { return }
                splitView.restoreInitialSidebarWidth(controller.workspace.sidebarWidth)
            }
            return splitView
        }

        func update(controller: ProjectSidebarController) {
            guard ProjectSidebarHostingUpdate.shouldReplaceController(
                current: self.controller,
                next: controller
            ) else { return }
            self.controller = controller
            sidebarHost?.rootView = ProjectSidebarSidebarContent(controller: controller)
            detailHost?.rootView = ProjectSidebarDetailContent(controller: controller)
        }

    }
}

final class ProjectSidebarSplitWidthCoordinator: NSObject, NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        ProjectSidebarWorkspaceValidator.minimumSidebarWidth
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(
            ProjectSidebarWorkspaceValidator.maximumSidebarWidth,
            splitView.bounds.width - 420 - splitView.dividerThickness
        )
    }
}

final class ProjectSidebarNativeSplitView: NSSplitView {
    private(set) var shouldReportSidebarWidthChanges = false
    private(set) var preferredSidebarWidth: Double?
    var sidebarWidthDidChangeByUser: ((Double) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let draggedDivider = subviews.first.map { sidebar in
            NSRect(
                x: sidebar.frame.maxX,
                y: bounds.minY,
                width: dividerThickness,
                height: bounds.height
            ).insetBy(dx: -3, dy: 0).contains(point)
        } ?? false

        super.mouseDown(with: event)
        if draggedDivider { commitUserSidebarWidth() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard shouldReportSidebarWidthChanges, let preferredSidebarWidth else { return }
        setPosition(preferredSidebarWidth, ofDividerAt: 0)
    }

    func applySidebarWidth(_ width: Double) {
        guard subviews.count >= 2 else { return }
        let bounded = min(
            ProjectSidebarWorkspaceValidator.maximumSidebarWidth,
            max(ProjectSidebarWorkspaceValidator.minimumSidebarWidth, width)
        )
        setPosition(bounded, ofDividerAt: 0)
        layoutSubtreeIfNeeded()
    }

    func rememberSidebarWidth(_ width: Double) {
        preferredSidebarWidth = min(
            ProjectSidebarWorkspaceValidator.maximumSidebarWidth,
            max(ProjectSidebarWorkspaceValidator.minimumSidebarWidth, width.rounded())
        )
    }

    func commitUserSidebarWidth() {
        guard shouldReportSidebarWidthChanges, let sidebar = subviews.first else { return }
        rememberSidebarWidth(sidebar.frame.width)
        guard let preferredSidebarWidth else { return }
        sidebarWidthDidChangeByUser?(preferredSidebarWidth)
    }

    func completeInitialWidthRestore() {
        shouldReportSidebarWidthChanges = true
    }

    func restoreInitialSidebarWidth(_ width: Double) {
        rememberSidebarWidth(width)
        applySidebarWidth(width)
        completeInitialWidthRestore()
    }
}

struct ProjectSidebarSidebarContent: View {
    @ObservedObject var controller: ProjectSidebarController

    @ViewBuilder
    var body: some View {
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
}

struct ProjectSidebarDetailContent: View {
    @ObservedObject var controller: ProjectSidebarController

    @ViewBuilder
    var body: some View {
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
