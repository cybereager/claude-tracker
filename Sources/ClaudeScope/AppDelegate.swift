import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        menuBarManager = MenuBarManager()
        menuBarManager?.startTracking()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
