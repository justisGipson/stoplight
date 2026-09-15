import AppKit
import Combine

public enum AppearanceMode: String, CaseIterable, Sendable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` means "inherit", which is what makes System work.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

public enum FontScale: String, CaseIterable, Sendable {
    case small, medium, large, extraLarge

    public var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Default"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    public var factor: Double {
        switch self {
        case .small: 0.88
        case .medium: 1.0
        case .large: 1.15
        case .extraLarge: 1.32
        }
    }
}

/// Persisted in `UserDefaults`. Small, flat, and read on launch — nothing here
/// warrants a file of its own.
@MainActor
public final class Settings: ObservableObject {
    public static let shared = Settings()

    @Published public var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published public var fontScale: FontScale {
        didSet { defaults.set(fontScale.rawValue, forKey: Keys.fontScale) }
    }

    /// Not stored here — it lives in `~/.claude/settings.json`, because Claude Code
    /// is what reads it. This mirrors the file so the UI can show and change it.
    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    @Published public var showCostInMenuBar: Bool {
        didSet { defaults.set(showCostInMenuBar, forKey: Keys.menuBarCost) }
    }

    @Published public var provider: ClaudeProvider = .anthropic
    @Published public var providerMessage: String?

    public func loadProvider() {
        provider = ClaudeSettingsFile.provider()
    }

    public func applyProvider(_ new: ClaudeProvider) {
        switch ClaudeSettingsFile.setProvider(new) {
        case .unchanged:
            providerMessage = nil
        case .written(let backup):
            providerMessage = "Saved. Applies to new sessions; existing ones keep their provider. "
                            + "Previous settings backed up to \(backup)."
        case .failed(let reason):
            providerMessage = "Could not update settings.json — \(reason)."
        }
        provider = ClaudeSettingsFile.provider()
    }

    private enum Keys {
        static let appearance = "appearance"
        static let fontScale = "fontScale"
        static let notifications = "notificationsEnabled"
        static let menuBarCost = "showCostInMenuBar"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "")
                  ?? .system
        fontScale = FontScale(rawValue: defaults.string(forKey: Keys.fontScale) ?? "")
                 ?? .medium
        // Default on: the notification is the half of this app the menu bar cannot do.
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        showCostInMenuBar = defaults.bool(forKey: Keys.menuBarCost)
    }

    /// Resets this app's own preferences. Deliberately does not touch the
    /// provider, which lives in Claude Code's config rather than ours.
    public func reset() {
        appearance = .system
        fontScale = .medium
        notificationsEnabled = true
        showCostInMenuBar = false
    }
}
