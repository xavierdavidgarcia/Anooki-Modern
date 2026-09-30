import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: no dock icon, no menu bar (we add our own status item).
app.setActivationPolicy(.accessory)
app.run()
