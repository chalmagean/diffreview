import AppKit
import DiffReviewCore
import SwiftUI

/// The live chat text style. Views that read it re-render when it changes in Settings.
@MainActor @Observable
final class ChatTextSettings {
    static let shared = ChatTextSettings()

    var preference: ChatTextPreference {
        didSet {
            guard preference != oldValue else { return }
            preference.save()
        }
    }

    private init() {
        preference = ChatTextPreference.load()
    }

    /// The chat font, `scale` times the chosen size (headings are larger, tables smaller).
    func font(scale: Double = 1, weight: Font.Weight = .regular) -> Font {
        .system(size: preference.size * scale, weight: weight, design: preference.typeface.design)
    }

    var lineSpacing: CGFloat { preference.lineSpacing }
    var paragraphSpacing: CGFloat { preference.paragraphSpacing }
    var theme: ChatTheme { ChatTheme(preference.theme) }
}

extension ChatTextPreference.Typeface {
    var design: Font.Design {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}

/// A chat theme's colors, each following light and dark mode where the theme does.
struct ChatTheme {
    let background: Color
    let text: Color
    /// Code blocks, tables and the message box.
    let panel: Color
    /// The user's own messages.
    let bubble: Color
    /// Night is dark even when the app is light.
    let colorScheme: ColorScheme?

    init(_ theme: ChatTextPreference.Theme) {
        switch theme {
        case .standard:
            background = Color(nsColor: .textBackgroundColor)
            text = Color(nsColor: .labelColor)
            panel = Color(nsColor: .controlBackgroundColor)
            bubble = Color.accentColor.opacity(0.15)
            colorScheme = nil
        case .paper:
            background = Self.dynamic(light: 0xF7F1E5, dark: 0x2A251F)
            text = Self.dynamic(light: 0x3A2F23, dark: 0xE9DDC9)
            panel = Self.dynamic(light: 0xEDE3D1, dark: 0x352E26)
            bubble = Self.dynamic(light: 0xE5D6BA, dark: 0x473C2F)
            colorScheme = nil
        case .night:
            background = Self.rgb(0x1D2026)
            text = Self.rgb(0xD5D9E0)
            panel = Self.rgb(0x272B33)
            bubble = Self.rgb(0x2E3A4F)
            colorScheme = .dark
        case .contrast:
            background = Self.dynamic(light: 0xFFFFFF, dark: 0x000000)
            text = Self.dynamic(light: 0x000000, dark: 0xFFFFFF)
            panel = Self.dynamic(light: 0xEFEFEF, dark: 0x1A1A1A)
            bubble = Self.dynamic(light: 0xD8E6FF, dark: 0x1C2E50)
            colorScheme = nil
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func rgb(_ hex: UInt32) -> Color { Color(nsColor: color(hex)) }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? color(dark) : color(light) })
    }
}

/// Colors a chat view with a theme: background, text, and the light/dark mode its controls
/// draw in (the app's own, except for themes that pick one).
private struct ChatThemeModifier: ViewModifier {
    let theme: ChatTheme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.text)
            .background(theme.background)
            .environment(\.colorScheme, theme.colorScheme ?? scheme)
    }
}

extension View {
    func chatThemed(_ theme: ChatTheme) -> some View {
        modifier(ChatThemeModifier(theme: theme))
    }
}
