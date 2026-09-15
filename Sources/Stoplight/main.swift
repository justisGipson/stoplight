import AppKit
import Foundation
import StoplightCore

// Diagnostic mode: run the bundled binary directly to inspect what the
// Accessibility API exposes for the terminals currently running Claude.
if CommandLine.arguments.contains("--diagnose") {
    let watcher = SessionWatcher()
    watcher.reload()
    if !SessionFocus.hasAccessibility { SessionFocus.requestAccessibility() }
    var report = SessionFocus.diagnose(sessions: watcher.sessions)
    var seen: Set<pid_t> = []
    for session in watcher.sessions {
        guard let app = SessionFocus.owningApplication(of: session.pid),
              seen.insert(app.processIdentifier).inserted else { continue }
        report += "menus for \(app.localizedName ?? "?"):\n"
        report += SessionFocus.diagnoseMenus(pid: app.processIdentifier)
    }
    FileHandle.standardError.write(Data(report.utf8))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon, no app menu

// Held for the process lifetime — this global is the only strong reference.
let controller = StatusItemController()

app.run()
