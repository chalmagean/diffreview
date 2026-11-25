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
    /// Height of one line of code, for sizing controls that sit on a diff row.
    private(set) var lineHeight: CGFloat

    private init() {
        let preference = FontPreference.load()
        self.preference = preference
        (nsFont, font, digitWidth, lineHeight) = Self.make(preference)
    }

    private func resolve() {
        (nsFont, font, digitWidth, lineHeight) = Self.make(preference)
    }

    private static func make(_ preference: FontPreference) -> (NSFont, Font, CGFloat, CGFloat) {
        let size = CGFloat(preference.size)
        let nsFont = preference.family.flatMap {
            NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size)
        } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: nsFont]).width
        let lineHeight = NSLayoutManager().defaultLineHeight(for: nsFont)
        return (nsFont, Font(nsFont as CTFont), digitWidth, lineHeight)
    }

    /// Installed fixed-pitch font families, by name.
    static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()
}

/// The live light/dark choice. Setting it restyles every window at once.
@MainActor @Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    var preference: AppearancePreference {
        didSet {
            guard preference != oldValue else { return }
            preference.save()
            apply()
        }
    }

    private init() {
        preference = AppearancePreference.load()
    }

    /// Pushes the preference onto the app; nil makes it follow the system again.
    func apply() {
        NSApp.appearance = switch preference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            DiffSettingsTab()
                .tabItem { Label("Diff", systemImage: "text.alignleft") }
            ChatSettingsTab()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// How the chats' text looks: typeface, size, line height and colors, with a live sample.
private struct ChatSettingsTab: View {
    @Bindable var settings = ChatTextSettings.shared

    /// An answer using most of what answers contain, to judge the settings by.
    private static let sample = """
        ## Why it's here

        `jump(to:)` scrolls **twice**: once now, and once after the table's next layout, \
        because the pinned header only updates then.

        - The first scroll moves the rows.
        - The second one fixes the header.

        ```swift
        scroll(to: rect.minY)
        ```
        """

    var body: some View {
        let preference = settings.preference
        Form {
            Picker("Typeface", selection: Binding(
                get: { preference.typeface },
                set: { settings.preference = preference.with(typeface: $0) }
            )) {
                ForEach(ChatTextPreference.Typeface.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Size") {
                Stepper(value: Binding(
                    get: { preference.size },
                    set: { settings.preference = preference.with(size: $0) }
                ), in: ChatTextPreference.sizeRange, step: 1) {
                    Text(verbatim: "\(Int(preference.size)) pt").monospacedDigit()
                }
            }
            LabeledContent("Line height") {
                HStack {
                    Slider(value: Binding(
                        get: { preference.lineHeight },
                        set: { settings.preference = preference.with(lineHeight: ($0 * 10).rounded() / 10) }
                    ), in: ChatTextPreference.lineHeightRange)
                    .frame(width: 160)
                    Text(String(format: "%.1f×", preference.lineHeight)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Picker("Theme", selection: Binding(
                get: { preference.theme },
                set: { settings.preference = preference.with(theme: $0) }
            )) {
                ForEach(ChatTextPreference.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Section("Preview") {
                AnswerText(text: Self.sample)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chatThemed(settings.theme)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { settings.preference = .default }
                    .disabled(preference == .default)
            }
        }
        .formStyle(.grouped)
    }
}

private extension ChatTextPreference {
    func with(typeface: Typeface? = nil, size: Double? = nil, lineHeight: Double? = nil, theme: Theme? = nil) -> Self {
        ChatTextPreference(typeface: typeface ?? self.typeface, size: size ?? self.size,
                           lineHeight: lineHeight ?? self.lineHeight, theme: theme ?? self.theme)
    }
}

private struct DiffSettingsTab: View {
    @Bindable var settings = CodeFontSettings.shared
    @Bindable var appearance = AppearanceSettings.shared

    var body: some View {
        let preference = settings.preference
        Form {
            Picker("Appearance", selection: $appearance.preference) {
                ForEach(AppearancePreference.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
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
                Button("Restore Defaults") {
                    settings.preference = .default
                    appearance.preference = .default
                }
                .disabled(preference == .default && appearance.preference == .default)
            }
        }
        .formStyle(.grouped)
    }

    /// The installed monospaced families, plus the saved one if it isn't among them
    /// (e.g. a proportional family, or a font that was uninstalled).
    private func families(including saved: String?) -> [String] {
        let all = CodeFontSettings.monospacedFamilies
        guard let saved, !all.contains(saved) else { return all }
        return [saved] + all
    }
}
