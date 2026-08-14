import AppKit
import Combine
import GhosttyKit

enum ProjectSidebarEntryStatus: Equatable {
    case running
    case stopped
    case unavailable

    var label: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "circle.fill"
        case .stopped: "circle"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }
}

enum ProjectSidebarQuitPolicy {
    static func entryRequiresConfirmation(_ surfaceStates: [Bool]) -> Bool {
        surfaceStates.contains(true)
    }

    static func entriesRequiringConfirmation(_ surfaceStatesByEntry: [[Bool]]) -> Int {
        surfaceStatesByEntry.count(where: entryRequiresConfirmation)
    }
}

enum ProjectSidebarPaneCloseDecision: Equatable {
    case ignore
    case closeWithoutConfirmation
    case closeWithConfirmation
}

enum ProjectSidebarPaneClosePolicy {
    static func decision(
        surfaceCount: Int,
        focusedSurfaceNeedsConfirmation: Bool
    ) -> ProjectSidebarPaneCloseDecision {
        guard surfaceCount > 1 else { return .ignore }
        return focusedSurfaceNeedsConfirmation
            ? .closeWithConfirmation
            : .closeWithoutConfirmation
    }

    static func perform(
        decision: ProjectSidebarPaneCloseDecision,
        requestConfirmation: (@escaping () -> Void) -> Void,
        close: @escaping () -> Void
    ) {
        switch decision {
        case .ignore:
            return
        case .closeWithoutConfirmation:
            close()
        case .closeWithConfirmation:
            requestConfirmation(close)
        }
    }
}

/// A runtime owns the complete split tree for one logical sidebar entry. It is deliberately not
/// a window controller: the workspace window is only a presentation host, while this object keeps
/// the surfaces alive when another entry is selected or the window is hidden.
final class ProjectSidebarRuntime: NSObject {
    let entryID: UUID
    let controller: BaseTerminalController

    init(entryID: UUID, ghostty: Ghostty.App, launchDirectory: String) {
        self.entryID = entryID
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.workingDirectory = launchDirectory
        configuration.strictWorkingDirectory = true
        self.controller = BaseTerminalController(ghostty, baseConfig: configuration)
        if case .leaf(let view) = self.controller.surfaceTree.root {
            self.controller.focusedSurface = view
        }
        super.init()
    }

    var status: ProjectSidebarEntryStatus {
        guard !controller.surfaceTree.isEmpty else { return .stopped }
        return controller.surfaceTree.contains(where: { !$0.processExited })
            ? .running
            : .stopped
    }

    var needsQuitConfirmation: Bool {
        ProjectSidebarQuitPolicy.entryRequiresConfirmation(
            controller.surfaceTree.map(\.needsConfirmQuit)
        )
    }
}

/// App-lifetime ownership for all workspace runtimes. The dictionary, rather than the window
/// hierarchy, is the source of truth for running-session counts and surface lookup.
final class ProjectSidebarRuntimeRegistry: ObservableObject {
    @Published private(set) var runtimes: [UUID: ProjectSidebarRuntime] = [:]

    func runtime(for entryID: UUID) -> ProjectSidebarRuntime? {
        runtimes[entryID]
    }

    func start(entryID: UUID, ghostty: Ghostty.App, launchDirectory: String) -> ProjectSidebarRuntime {
        if let runtime = runtimes[entryID] { return runtime }
        let runtime = ProjectSidebarRuntime(entryID: entryID, ghostty: ghostty, launchDirectory: launchDirectory)
        runtimes[entryID] = runtime
        return runtime
    }

    func stop(entryID: UUID) {
        runtimes.removeValue(forKey: entryID)?.controller.stopAllSurfacesImmediately()
    }

    func stopAll() {
        runtimes.values.forEach { $0.controller.stopAllSurfacesImmediately() }
        runtimes.removeAll()
    }

    func isRunning(entryID: UUID) -> Bool {
        runtimes[entryID]?.status == .running
    }

    var quitConfirmationEntryCount: Int {
        runtimes.values.count(where: \.needsQuitConfirmation)
    }

    var allSurfaceViews: [Ghostty.SurfaceView] {
        runtimes.values.flatMap { Array($0.controller.surfaceTree) }
    }
}
