import AppKit

let app = NSApplication.shared
// Hide from Dock — acts like a menu bar agent
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
