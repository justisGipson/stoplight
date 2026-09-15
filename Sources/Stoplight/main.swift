import AppKit
import StoplightCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon, no app menu

// Held for the process lifetime — this global is the only strong reference.
let controller = StatusItemController()

app.run()
