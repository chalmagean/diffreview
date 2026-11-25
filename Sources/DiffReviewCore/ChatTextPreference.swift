import Foundation

/// How text in the chats looks, as chosen in Settings.
public struct ChatTextPreference: Equatable, Sendable {
    public enum Typeface: String, CaseIterable, Sendable {
        case system, serif, rounded, monospaced

        public var title: String {
            switch self {
            case .system: "System"
            case .serif: "Serif"
            case .rounded: "Rounded"
            case .monospaced: "Monospaced"
            }
        }
    }

    public enum Theme: String, CaseIterable, Sendable {
        /// The window's own colors, light or dark with the app.
        case standard
        /// Warm off-white with dark brown text (a dim sepia in dark mode).
        case paper
        /// Always dark, with softened text.
        case night
        /// Black on white, or white on black in dark mode.
        case contrast

        public var title: String {
            switch self {
            case .standard: "Standard"
            case .paper: "Paper"
            case .night: "Night"
            case .contrast: "High contrast"
            }
        }
    }

    public static let sizeRange: ClosedRange<Double> = 11...26
    public static let lineHeightRange: ClosedRange<Double> = 1.2...2.2
    public static let `default` = ChatTextPreference(typeface: .system, size: 15, lineHeight: 1.5, theme: .standard)

    static let typefaceKey = "chatTypeface"
    static let sizeKey = "chatFontSize"
    static let lineHeightKey = "chatLineHeight"
    static let themeKey = "chatTheme"

    public let typeface: Typeface
    /// Point size, within `sizeRange`.
    public let size: Double
    /// Line height as a multiple of the size, within `lineHeightRange`.
    public let lineHeight: Double
    public let theme: Theme

    public init(typeface: Typeface, size: Double, lineHeight: Double, theme: Theme) {
        self.typeface = typeface
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        self.lineHeight = min(max(lineHeight, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound)
        self.theme = theme
    }

    /// Points added between lines: fonts already set lines about 1.2 times their size apart.
    public var lineSpacing: Double { max(0, size * (lineHeight - 1.2)) }

    /// Space between paragraphs, list blocks and the like.
    public var paragraphSpacing: Double { size * 0.7 }

    public static func load(from defaults: UserDefaults = .standard) -> ChatTextPreference {
        let size = defaults.double(forKey: sizeKey)       // 0 when missing
        let lineHeight = defaults.double(forKey: lineHeightKey)
        return ChatTextPreference(
            typeface: defaults.string(forKey: typefaceKey).flatMap(Typeface.init(rawValue:)) ?? Self.default.typeface,
            size: size > 0 ? size : Self.default.size,
            lineHeight: lineHeight > 0 ? lineHeight : Self.default.lineHeight,
            theme: defaults.string(forKey: themeKey).flatMap(Theme.init(rawValue:)) ?? Self.default.theme)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(typeface.rawValue, forKey: Self.typefaceKey)
        defaults.set(size, forKey: Self.sizeKey)
        defaults.set(lineHeight, forKey: Self.lineHeightKey)
        defaults.set(theme.rawValue, forKey: Self.themeKey)
    }
}
