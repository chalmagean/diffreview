import AppKit
import DiffReviewCore
import SwiftUI

/// The live code font, shared by every diff row. Views that read it re-render when it changes.
@MainActor @Observable
final class CodeFontSettings {
    static let shared = CodeFontSettings()

    var preference: FontPreference {
        didSet {
            guard preference != oldValue else { return }
            preference.save()
            resolve()
        }
    }

    private(set) var nsFont: NSFont
    private(set) var font: Font
    /// Width of one digit, for sizing the line-number gutters.
    private(set) var digitWidth: CGFloat

    private init() {
        let preference = FontPreference.load()
        self.preference = preference
        (nsFont, font, digitWidth) = Self.make(preference)
    }

    private func resolve() {
        (nsFont, font, digitWidth) = Self.make(preference)
    }

    private static func make(_ preference: FontPreference) -> (NSFont, Font, CGFloat) {
        let size = CGFloat(preference.size)
        let nsFont = preference.family.flatMap {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size)
        } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: nsFont]).width
        return (nsFont, Font(nsFont as CTFont), digitWidth)
    }

    /// Installed fixed-pitch font families, by name.
    static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()
}

struct SettingsView: View {
    @Bindable var settings = CodeFontSettings.shared

    var body: some View {
        let preference = settings.preference
        Form {
            Picker("Code font", selection: Binding(
                get: { preference.family },
                set: { settings.preference = FontPreference(family: $0, size: preference.size) }
            )) {
                Text("System (SF Mono)").tag(String?.none)
                Divider()
                ForEach(families(including: preference.family), id: \.self) { family in
                    Text(family).tag(Optional(family))
                }
            }
            LabeledContent("Size") {
                Stepper(value: Binding(
                    get: { preference.size },
                    set: { settings.preference = FontPreference(family: preference.family, size: $0) }
                ), in: FontPreference.sizeRange, step: 1) {
                    Text(verbatim: "\(Int(preference.size)) pt").monospacedDigit()
                }
            }
            Section("Preview") {
                Text(verbatim: "func greet(_ name: String) -> String {\n    return \"Hello, \\(name)!\" // 0O 1lI\n}")
                    .font(settings.font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { settings.preference = .default }
                    .disabled(preference == .default)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The installed monospaced families, plus the saved one if it isn't among them
    /// (e.g. a proportional family, or a font that was uninstalled).
    private func families(including saved: String?) -> [String] {
        let all = CodeFontSettings.monospacedFamilies
        guard let saved, !all.contains(saved) else { return all }
        return [saved] + all
    }
}
