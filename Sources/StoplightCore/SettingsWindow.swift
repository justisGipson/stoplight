import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Stoplight Settings"
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func applyAppearance() {
        window?.appearance = settings.appearance.nsAppearance
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row("Appearance",
                note: "Applies to this window and the hover panel. The menu bar icon "
                    + "always follows the system, so it stays legible against the real "
                    + "menu bar.") {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            row("Text size",
                note: "Scales the hover panel and the usage window. The menu bar icon is "
                    + "fixed by the height of the menu bar itself.") {
                Picker("", selection: $settings.fontScale) {
                    ForEach(FontScale.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Spacer()

            HStack {
                Spacer()
                Button("Reset to defaults") { settings.reset() }
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 380, height: 260, alignment: .topLeading)
    }

    private func row<Content: View>(_ title: String,
                                    note: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
