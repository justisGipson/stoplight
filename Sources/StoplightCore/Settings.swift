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

    private enum Keys {
        static let appearance = "appearance"
        static let fontScale = "fontScale"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "")
                  ?? .system
        fontScale = FontScale(rawValue: defaults.string(forKey: Keys.fontScale) ?? "")
                 ?? .medium
    }

    public func reset() {
        appearance = .system
        fontScale = .medium
    }
}
