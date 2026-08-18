import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let home = HomeWindowController()
        mainWindowController = home
        home.showWindow(nil)
        home.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
