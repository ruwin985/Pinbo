import AppKit

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.delegate = appDelegate
application.run()
