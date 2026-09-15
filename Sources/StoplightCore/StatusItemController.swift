import AppKit
import SwiftUI
import QuartzCore

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

    private var state = LightState(failed: 0, attention: 1, running: 2) {
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
        panel.ignoresMouseEvents = true      // hover detail only; never intercepts clicks
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }()

    /// Every lamp permutation worth eyeballing, for milestone 1 verification.
    private static let demoStates: [LightState] = [
        LightState(failed: 0, attention: 0, running: 0),
        LightState(failed: 0, attention: 0, running: 2),
        LightState(failed: 0, attention: 1, running: 0),
        LightState(failed: 1, attention: 0, running: 0),
        LightState(failed: 0, attention: 1, running: 2),
        LightState(failed: 1, attention: 2, running: 3),
    ]
    private var demoIndex = 0

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

        render()
    }

    // MARK: - Rendering

    private func render() {
        statusItem.button?.image = StoplightIcon.image(for: state)
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
        hoverTask = nil
        hoverPanel.orderOut(nil)
    }

    private func showHoverPanel() {
        layoutHoverPanel()
        hoverPanel.orderFrontRegardless()   // visible without activating the app
    }

    private func layoutHoverPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let host = NSHostingView(rootView: PopoverView(state: state))
        host.layout()
        let size = host.fittingSize
        hoverPanel.contentView = host
        hoverPanel.setContentSize(size)

        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        hoverPanel.setFrameOrigin(NSPoint(x: onScreen.midX - size.width / 2,
                                          y: onScreen.minY - size.height - 6))
    }

    // MARK: - Click

    @objc private func buttonClicked() {
        hoverTask?.cancel()
        hoverPanel.orderOut(nil)

        guard let button = statusItem.button else { return }
        buildMenu().popUp(positioning: nil,
                          at: NSPoint(x: 0, y: button.bounds.height + 4),
                          in: button)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: state.summary, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let cycle = NSMenuItem(title: "Cycle demo state",
                               action: #selector(cycleDemoState), keyEquivalent: "d")
        cycle.target = self
        menu.addItem(cycle)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Stoplight",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    @objc private func cycleDemoState() {
        demoIndex = (demoIndex + 1) % Self.demoStates.count
        state = Self.demoStates[demoIndex]
    }
}
