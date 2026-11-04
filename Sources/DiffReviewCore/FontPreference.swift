import Foundation

/// The font used for code in the diff, as chosen in Settings.
public struct FontPreference: Equatable, Sendable {
    public static let sizeRange: ClosedRange<Double> = 9...28
    public static let `default` = FontPreference(family: nil, size: 12)

    static let familyKey = "codeFontFamily"
    static let sizeKey = "codeFontSize"

    /// A font family name, or nil for the system monospaced font (SF Mono).
    public let family: String?
    /// Point size, always within `sizeRange`.
    public let size: Double

    public init(family: String?, size: Double) {
        let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.family = trimmed?.isEmpty == false ? trimmed : nil
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }

    public static func load(from defaults: UserDefaults = .standard) -> FontPreference {
        let stored = defaults.double(forKey: sizeKey) // 0 when missing
        return FontPreference(family: defaults.string(forKey: familyKey),
                              size: stored > 0 ? stored : Self.default.size)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let family {
            defaults.set(family, forKey: Self.familyKey)
        } else {
            defaults.removeObject(forKey: Self.familyKey)
        }
        defaults.set(size, forKey: Self.sizeKey)
    }
}
