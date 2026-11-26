import AppKit
import DiffReviewCore

/// Syntax colours, GitHub's (Primer "prettylights"), for light and dark appearances. The
/// tokens come from `Syntax` in DiffReviewCore, worked out once per file when it's prepared.
enum SyntaxColors {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.isDark ? rgb(dark) : rgb(light) }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static let keyword = dynamic(0xCF222E, 0xFF7B72)
    private static let string = dynamic(0x0A3069, 0xA5D6FF)
    private static let comment = dynamic(0x6E7781, 0x8B949E)
    private static let constant = dynamic(0x0550AE, 0x79C0FF)
    private static let type = dynamic(0x953800, 0xFFA657)
    private static let function = dynamic(0x8250DF, 0xD2A8FF)
    private static let tag = dynamic(0x116329, 0x7EE787)

    static func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .constant: return constant
        case .type: return type
        case .function: return function
        case .tag: return tag
        }
    }
}
