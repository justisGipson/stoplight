import AppKit
import Darwin

/// Finds the GUI application that owns a session and brings it forward.
///
/// A `claude` process sits several levels below its terminal — typically
/// `claude` → `zsh` → `login` → Terminal/Ghostty/iTerm. Walking the parent chain
/// until a real application turns up needs no special permission.
///
/// Focusing the exact *window or tab* does need one: macOS gates that behind
/// Accessibility or per-app Automation consent, and terminals differ in what they
/// expose. Raising the owning app is the part that works everywhere, today.
public enum SessionFocus {
    public static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// First ancestor that is a real, activatable application.
    public static func owningApplication(of pid: pid_t, maxDepth: Int = 12) -> NSRunningApplication? {
        var current: pid_t? = pid
        for _ in 0..<maxDepth {
            guard let pid = current else { break }
            if let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy == .regular {
                return app
            }
            current = parentPid(of: pid)
        }
        return nil
    }

    public static func name(forSessionPid pid: pid_t) -> String? {
        owningApplication(of: pid)?.localizedName
    }

    @discardableResult
    public static func focus(sessionPid pid: pid_t) -> Bool {
        guard let app = owningApplication(of: pid) else { return false }
        return app.activate()
    }
}
