import AppKit
import SwiftUI
import QuartzCore
import Combine

/// Owns the menu bar item and the two gestures it has to serve.
///
/// Hover and click both live on one `NSStatusItem.button`, which AppKit does not
/// support directly: assigning `statusItem.menu` would make AppKit swallow every
/// mouse event and kill the hover path. So the button's action is handled manually
/// and the menu is popped up by hand.
///
/// The hover surface is an `NSPanel`, not an `NSPopover`. A popover from a
/// background `.accessory` app needs the app activated to display reliably, and
/// activating on hover would pull focus off whatever you were typing in. A
/// non-activating panel renders without ever taking focus.
///
/// The icon itself is static. An earlier version rotated it upright on hover,
/// which meant resizing the status item every frame and dragging AppKit through a
/// full menu bar layout each time — visibly choppy. Drawing it upright to begin
/// with removes the animation, the resizing and the scaling blur all at once.
@MainActor
public final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var trackingArea: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private var appearanceObserver: NSKeyValueObservation?


    /// Delay before hover engages, so sweeping across the menu bar on the way to
    /// something else doesn't set the whole thing spinning.
    private let hoverIntent: TimeInterval = 0.22

    private let watcher = SessionWatcher()
    private let scoreboard = ScoreboardWindowController()
    private let settings = Settings.shared
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private var settingsObserver: AnyCancellable?
    /// Watches the pointer while the panel is up, so moving from the icon onto the
    /// panel keeps it open and moving away anywhere else closes it.
    private var mouseMonitor: Any?
    private var hoverHost: NSHostingView<PopoverView>?
    /// Fires exactly when the next just-finished session stops counting as
    /// attention. A one-shot rather than a poll, so idle cost stays at zero.
    private var decayTask: Task<Void, Never>?
    /// Crashes are written through to disk as they happen; the in-memory casualty
    /// list is cleared by dismissal and lost on quit, but the tally should survive.
    private var recordedCrashes: Set<pid_t> = []

    private var state = LightState() {
        didSet { if state != oldValue { render() } }
    }

    private lazy var hoverPanel: NSPanel = {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false     // rows are clickable
        panel.acceptsMouseMovedEvents = true // and SwiftUI needs these for .onHover
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()

    public override init() {
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            installTrackingArea(on: button)
        }

        // The menu bar flips light/dark independently of the app; the housing and
        // unlit lamps derive from labelColor, so they need a redraw when it does.
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.render() }
        }

        if settings.notificationsEnabled { Notifier.shared.requestAuthorization() }
        watcher.onChange = { [weak self] in self?.refreshState() }
        watcher.start()
        refreshState()
        settingsObserver = settings.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.applySettings() }
        }
        applySettings()
        render()
    }

    /// Combined cost of what is running right now — not a daily total, which
    /// would need a full transcript pass on every refresh.
    private func menuBarText() -> String? {
        guard settings.showCostInMenuBar else { return nil }
        let live = watcher.sessions.compactMap { watcher.snapshots[$0.sessionId]?.costUSD }
        guard !live.isEmpty else { return nil }
        let total = live.reduce(0, +)
        return total >= 10 ? String(format: "$%.0f", total) : String(format: "$%.2f", total)
    }

    private func applySettings() {
        // Only the app's own surfaces follow this. The status item keeps the system
        // appearance: it is drawn onto the real menu bar, and forcing light artwork
        // onto a dark bar would make it invisible.
        hoverPanel.appearance = settings.appearance.nsAppearance
        settingsWindow.applyAppearance()
        Notifier.shared.isEnabled = settings.notificationsEnabled
        if settings.notificationsEnabled { Notifier.shared.requestAuthorization() }
        render()
        if hoverPanel.isVisible { layoutHoverPanel() }
    }

    // MARK: - State

    private func refreshState() {
        let now = Date()
        state = LightState(sessions: watcher.sessions,
                           casualties: watcher.casualties,
                           snapshots: watcher.snapshots,
                           now: now)
        recordNewCrashes()
        Notifier.shared.isEnabled = settings.notificationsEnabled
        Notifier.shared.reconcile(sessions: watcher.sessions,
                                  casualties: watcher.casualties,
                                  snapshots: watcher.snapshots,
                                  now: now)
        if hoverPanel.isVisible { layoutHoverPanel() }
        scheduleAttentionDecay(now: now)
    }

    private func recordNewCrashes() {
        let unrecorded = watcher.casualties.filter { !recordedCrashes.contains($0.pid) }
        guard !unrecorded.isEmpty else { return }

        var store = ScoreboardStore.load()
        for casualty in unrecorded {
            recordedCrashes.insert(casualty.pid)
            store.crashes.append("\(casualty.folder)|\(Int(casualty.diedAt.timeIntervalSince1970))")
        }
        store.save()
    }

    /// Attention expires on a clock, not on a filesystem event, so schedule a
    /// single wake-up for the earliest expiry rather than polling for it.
    private func scheduleAttentionDecay(now: Date) {
        decayTask?.cancel()
        decayTask = nil

        let expiries = watcher.sessions.compactMap { $0.attentionExpiry() }
                     + watcher.casualties.map { $0.expiry() }
        let next = expiries.filter { $0 > now }.min()
        guard let next else { return }

        decayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.refreshState()
        }
    }

    // MARK: - Rendering

    private func render() {
        statusItem.button?.image = StoplightIcon.image(for: state, trailingText: menuBarText())
        // No toolTip: it competes with the hover panel and wins, because AppKit
        // owns it. The panel is the tooltip.
        statusItem.button?.setAccessibilityLabel("Stoplight: \(state.summary)")
        if hoverPanel.isVisible { layoutHoverPanel() }
    }

    private func installTrackingArea(on button: NSStatusBarButton) {
        if let existing = trackingArea { button.removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Hover

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.hoverIntent))
            guard !Task.isCancelled else { return }
            self.showHoverPanel()
        }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        hoverTask?.cancel()
        // Leaving the icon may just mean heading for the panel, so give the pointer
        // a moment to arrive before deciding.
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self?.closePanelIfPointerLeft()
        }
    }

    private func showHoverPanel() {
        layoutHoverPanel()
        hoverPanel.orderFrontRegardless()   // visible without activating the app
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            MainActor.assumeIsolated { self.closePanelIfPointerLeft() }
        }
    }

    private func hideHoverPanel() {
        hoverPanel.orderOut(nil)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// The panel and the icon are separate surfaces with a gap between them, so
    /// neither one's own tracking can decide this alone.
    private func closePanelIfPointerLeft() {
        guard hoverPanel.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        if hoverPanel.frame.insetBy(dx: -10, dy: -10).contains(pointer) { return }
        if let button = statusItem.button, let window = button.window {
            let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
            if onScreen.insetBy(dx: -10, dy: -10).contains(pointer) { return }
        }
        hideHoverPanel()
    }

    private func layoutHoverPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let content = PopoverView(
            state: state,
            sessions: watcher.sessions,
            casualties: watcher.casualties,
            snapshots: watcher.snapshots,
            now: Date(),
            fontScale: settings.fontScale.factor,
            onSelect: { [weak self] session in self?.focus(session) })

        // Reuse the hosting view rather than rebuilding it: a fresh one on every
        // state change would drop the row the pointer is currently over.
        let host: NSHostingView<PopoverView>
        if let existing = hoverHost {
            existing.rootView = content
            host = existing
        } else {
            host = NSHostingView(rootView: content)
            hoverHost = host
            hoverPanel.contentView = host
        }
        host.layout()
        hoverPanel.setContentSize(host.fittingSize)
        let size = host.fittingSize

        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        hoverPanel.setFrameOrigin(NSPoint(x: onScreen.midX - size.width / 2,
                                          y: onScreen.minY - size.height - 6))
    }

    /// Clicking a session raises its terminal. Matching the exact window needs
    /// Accessibility access, so ask for it here — at the moment the user asked for
    /// something that needs it — rather than nagging at launch.
    private func focus(_ session: Session) {
        hideHoverPanel()
        let title = watcher.snapshots[session.sessionId]?.aiTitle
        if case .needsAccessibility = SessionFocus.focus(
            session: session, titles: [title].compactMap { $0 }) {
            SessionFocus.requestAccessibility()
        }
    }

    // MARK: - Click

    @objc private func buttonClicked() {
        hoverTask?.cancel()
        hideHoverPanel()

        guard let button = statusItem.button else { return }
        buildMenu().popUp(positioning: nil,
                          at: NSPoint(x: 0, y: button.bounds.height + 4),
                          in: button)
    }


    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func showScoreboard() {
        scoreboard.show()
    }

    @objc private func dismissFailures() {
        watcher.dismissCasualties()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: state.summary, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())


        if !watcher.casualties.isEmpty {
            let count = watcher.casualties.count
            let dismiss = NSMenuItem(
                title: "Dismiss \(count) failure\(count == 1 ? "" : "s")",
                action: #selector(dismissFailures), keyEquivalent: "")
            dismiss.target = self
            menu.addItem(dismiss)
            menu.addItem(.separator())
        }

        let preferences = NSMenuItem(title: "Settings…",
                                     action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)

        let usage = NSMenuItem(title: "Usage & Scoreboard…",
                               action: #selector(showScoreboard), keyEquivalent: "")
        usage.target = self
        menu.addItem(usage)
        menu.addItem(.separator())

        let diagnostics = NSMenuItem(title: watcher.diagnostics.summary,
                                     action: nil, keyEquivalent: "")
        diagnostics.isEnabled = false
        menu.addItem(diagnostics)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Stoplight",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

}
