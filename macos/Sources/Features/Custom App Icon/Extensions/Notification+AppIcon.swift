import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// Ghostty -> DockTilePlugin
    #if GHOSTTY_DEV
    static let ghosttyIconDidChange = Notification.Name("com.northshoreautomation.ghostty-dev.iconDidChange")
    #else
    static let ghosttyIconDidChange = Notification.Name("com.mitchellh.ghostty.iconDidChange")
    #endif
}
