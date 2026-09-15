import AppKit
import ApplicationServices
import Darwin

public enum FocusOutcome: Equatable {
    case raisedWindow(String)
    case raisedApplication(String)
    /// The app was raised, but picking the right window needs Accessibility access.
    case needsAccessibility(String)
    case notFound
}

/// Brings the terminal running a session to the front.
///
/// Two layers. Walking the parent chain to the owning application needs no
/// permission and always works: `claude` → `zsh` → `login` → Terminal/Ghostty/iTerm.
/// Picking the *right* window or tab within that app needs the Accessibility API,
/// which macOS gates behind explicit user consent.
///
/// Matching is by title. Claude Code sets the terminal tab title itself — the
/// `terminalTitleFromRename` setting describes exactly that — so the session's own
/// name and its folder are what to look for.
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

    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system consent dialog. Only ever called from an explicit click.
    public static func requestAccessibility() {
        // Spelled out rather than referencing the global, which Swift 6 treats as
        // shared mutable state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - Focusing

    /// - Parameter titles: extra strings the window might be named after. In
    ///   practice this is the session's AI topic title, which is what Claude Code
    ///   puts in the terminal title bar — the folder and session name never appear
    ///   there.
    @discardableResult
    public static func focus(session: Session, titles: [String] = []) -> FocusOutcome {
        guard let app = owningApplication(of: session.pid) else { return .notFound }
        let appName = app.localizedName ?? "the terminal"

        guard AXIsProcessTrusted() else {
            app.activate()
            return .needsAccessibility(appName)
        }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        let targets = (titles + [session.name, session.folder]).filter { !$0.isEmpty }

        // With a single window there is nothing to choose between, and no terminal
        // exposes its tabs to AX anyway — raising the app is the whole job.
        let candidates = windows(of: element)
        guard candidates.count > 1 else {
            app.activate()
            return .raisedApplication(appName)
        }

        for window in candidates {
            if let title = string(window, kAXTitleAttribute), matches(title, any: targets) {
                raise(window)
                app.activate()
                return .raisedWindow(title)
            }
            // Terminals put tabs inside one window, so the window title may name
            // only the frontmost tab. Look for the tab itself and press it.
            if let tab = tab(in: window, matching: targets) {
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
                raise(window)
                app.activate()
                return .raisedWindow(string(tab, kAXTitleAttribute) ?? session.folder)
            }
        }

        app.activate()
        return .raisedApplication(appName)
    }

    static func matches(_ title: String, any targets: [String]) -> Bool {
        let haystack = title.lowercased()
        return targets.contains { !$0.isEmpty && haystack.contains($0.lowercased()) }
    }

    private static func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func windows(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
                == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// Depth-limited: a terminal's tab bar sits near the top of the tree, and the
    /// full view hierarchy is far too big to walk exhaustively on a click.
    private static func tab(in element: AXUIElement,
                            matching targets: [String],
                            depth: Int = 0) -> AXUIElement? {
        guard depth < 5 else { return nil }
        for child in children(of: element) {
            let role = string(child, kAXRoleAttribute)
            if role == kAXRadioButtonRole || role == kAXTabGroupRole {
                if role == kAXRadioButtonRole,
                   let title = string(child, kAXTitleAttribute), matches(title, any: targets) {
                    return child
                }
            }
            if let found = tab(in: child, matching: targets, depth: depth + 1) { return found }
        }
        return nil
    }
}

// MARK: - Diagnostics

extension SessionFocus {
    /// Dumps what the Accessibility API actually exposes, so window targeting can
    /// be debugged against a real terminal instead of guessed at.
    public static func diagnose(sessions: [Session]) -> String {
        var out = "accessibility trusted: \(AXIsProcessTrusted())\n"
        out += "bundle: \(Bundle.main.bundleIdentifier ?? "none")\n\n"

        for session in sessions {
            out += "session pid=\(session.pid) name=\(session.name) folder=\(session.folder)\n"
            guard let app = owningApplication(of: session.pid) else {
                out += "  no owning application\n\n"
                continue
            }
            out += "  app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) "
                 + "pid=\(app.processIdentifier)\n"

            guard AXIsProcessTrusted() else {
                out += "  (not trusted — cannot enumerate windows)\n\n"
                continue
            }

            let element = AXUIElementCreateApplication(app.processIdentifier)
            let found = windowList(of: element)
            out += "  AX windows: \(found.count)\n"
            for (index, window) in found.enumerated() {
                let title = string(window, kAXTitleAttribute) ?? "<no title>"
                let role = string(window, kAXRoleAttribute) ?? "?"
                out += "    [\(index)] role=\(role) title=\(title.debugDescription)\n"
                out += describeChildren(window, depth: 1, limit: 3)
            }
            out += "\n"
        }
        return out
    }

    static func windowList(of application: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
                == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func describeChildren(_ element: AXUIElement, depth: Int, limit: Int) -> String {
        guard depth <= limit else { return "" }
        var out = ""
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success, let kids = value as? [AXUIElement] else { return "" }

        for child in kids.prefix(12) {
            let role = string(child, kAXRoleAttribute) ?? "?"
            let title = string(child, kAXTitleAttribute)
            let indent = String(repeating: "  ", count: depth + 2)
            out += "\(indent)role=\(role)"
            if let title, !title.isEmpty { out += " title=\(title.debugDescription)" }
            out += "\n"
            if role == kAXTabGroupRole || role.contains("Tab") || depth < 2 {
                out += describeChildren(child, depth: depth + 1, limit: limit)
            }
        }
        return out
    }
}

extension SessionFocus {
    /// Dumps an application's menu bar. A standard macOS Window menu lists open
    /// windows and tabs by title, and menu items can be pressed via AX — which
    /// would work even for a terminal whose window contents expose nothing.
    public static func diagnoseMenus(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value)
                == .success, let raw = value else {
            return "  no menu bar exposed\n"
        }
        let bar = raw as! AXUIElement

        var out = ""
        for menu in childElements(bar) {
            let name = string(menu, kAXTitleAttribute) ?? "?"
            guard ["Window", "Shell", "Tab", "View"].contains(name) else { continue }
            out += "  menu: \(name)\n"
            for submenu in childElements(menu) {
                for item in childElements(submenu) {
                    let title = string(item, kAXTitleAttribute) ?? ""
                    if !title.isEmpty { out += "    item: \(title.debugDescription)\n" }
                }
            }
        }
        return out.isEmpty ? "  no Window/Tab menus found\n" : out
    }

    static func childElements(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
