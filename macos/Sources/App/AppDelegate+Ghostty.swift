import AppKit

// MARK: Ghostty Delegate

/// This implements the Ghostty app delegate protocol which is used by the Ghostty
/// APIs for app-global information.
extension AppDelegate: Ghostty.Delegate {
    func ghosttySurface(id: UUID) -> Ghostty.SurfaceView? {
        if let workspaceSurface = projectSidebarController.runtimeRegistry.allSurfaceViews.first(where: { $0.id == id }) {
            return workspaceSurface
        }

        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }

            for surface in controller.surfaceTree where surface.id == id {
                return surface
            }
        }

        return nil
    }
}
