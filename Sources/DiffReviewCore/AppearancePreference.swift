import Foundation

/// Light or dark mode for the app, as chosen in Settings.
public enum AppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark

    public static let `default` = AppearancePreference.system

    static let key = "appearance"

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppearancePreference {
        defaults.string(forKey: key).flatMap(AppearancePreference.init(rawValue:)) ?? .default
    }

    public func save(to defaults: UserDefaults = .standard) {
        if self == .default {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(rawValue, forKey: Self.key)
        }
    }
}
