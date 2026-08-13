import AppKit
import SwiftUI

final class ProjectSidebarWindowController: NSWindowController, NSWindowDelegate {
    unowned let sidebarController: ProjectSidebarController

    init(sidebarController: ProjectSidebarController) {
        self.sidebarController = sidebarController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghostty"
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ProjectSidebarView(controller: sidebarController))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sidebarController.hide()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        sidebarController.updateRuntimeFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        sidebarController.updateRuntimeFocus()
    }
}
