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

/// The Settings window, laid out like the system apps' settings: each pane is a tab in the
/// toolbar, the window is titled after the selected pane and resizes to fit it.
@MainActor
enum SettingsWindow {
    static func make() -> NSWindow {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addPane("Diff", symbol: "plus.forwardslash.minus", DiffSettingsPane())
        tabs.addPane("Chat", symbol: "bubble.left.and.text.bubble.right", ChatSettingsPane())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        tabs.fitWindow(animate: false)
        window.center()
        return window
    }
}

private final class SettingsTabViewController: NSTabViewController {
    func addPane(_ title: String, symbol: String, _ pane: some View) {
        let host = NSHostingController(rootView: pane)
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow(animate: true)
    }

    /// Resizes the window to the selected pane, keeping its top edge where it is.
    func fitWindow(animate: Bool) {
        guard let window = view.window,
              let pane = tabViewItems[safe: selectedTabViewItemIndex]?.viewController?.view else { return }
        let size = pane.fittingSize
        let current = view.frame.size
        var frame = window.frame
        frame.origin.y -= size.height - current.height
        frame.size.height += size.height - current.height
        frame.size.width += size.width - current.width
        window.setFrame(frame, display: true, animate: animate)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Layout

private enum SettingsLayout {
    static let width: CGFloat = 520
    static let labelWidth: CGFloat = 150
    static let controlWidth: CGFloat = 220
}

/// A pane: rows of right-aligned labels with their controls beside them, in groups split by dividers.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(width: SettingsLayout.width)
    }
}

private struct SettingRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .frame(width: SettingsLayout.labelWidth, alignment: .trailing)
            control
        }
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.vertical, 8) }
}

/// A point size, typed in or stepped: "[13][⌃⌄] pt".
private struct PointSizeField: View {
    @Binding var size: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("Size", value: Binding(get: { size }, set: { size = $0.rounded() }),
                      format: .number.precision(.fractionLength(0)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 44)
            Stepper("Size", value: $size, in: range, step: 1)
                .labelsHidden()
            Text("pt")
        }
    }
}

/// A sample of how the settings look, framed like a document.
private struct PreviewBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
}

/// The pane's last row: a Restore Defaults button at the bottom right.
private struct RestoreDefaultsRow: View {
    let isDefault: Bool
    let restore: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Restore Defaults", action: restore)
                .disabled(isDefault)
        }
        .padding(.top, 6)
    }
}

// MARK: - Panes

private struct DiffSettingsPane: View {
    @Bindable var settings = CodeFontSettings.shared
    @Bindable var appearance = AppearanceSettings.shared

    var body: some View {
        let preference = settings.preference
        SettingsPane {
            SettingRow(label: "Appearance") {
                Picker("Appearance", selection: $appearance.preference) {
                    ForEach(AppearancePreference.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: SettingsLayout.controlWidth)
            }

            SettingsDivider()

            SettingRow(label: "Code font") {
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
                .labelsHidden()
                .frame(width: SettingsLayout.controlWidth)
            }
            SettingRow(label: "Size") {
                PointSizeField(size: Binding(
                    get: { preference.size },
                    set: { settings.preference = FontPreference(family: preference.family, size: $0) }
                ), range: FontPreference.sizeRange)
            }

            SettingsDivider()

            PreviewBox {
                Text(verbatim: "func greet(_ name: String) -> String {\n    return \"Hello, \\(name)!\" // 0O 1lI\n}")
                    .font(settings.font)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            RestoreDefaultsRow(isDefault: preference == .default && appearance.preference == .default) {
                settings.preference = .default
                appearance.preference = .default
            }
        }
    }

    /// The installed monospaced families, plus the saved one if it isn't among them
    /// (e.g. a proportional family, or a font that was uninstalled).
    private func families(including saved: String?) -> [String] {
        let all = CodeFontSettings.monospacedFamilies
        guard let saved, !all.contains(saved) else { return all }
        return [saved] + all
    }
}

/// How the chats' text looks: typeface, size, line height and colors, with a live sample.
private struct ChatSettingsPane: View {
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
        SettingsPane {
            SettingRow(label: "Typeface") {
                Picker("Typeface", selection: Binding(
                    get: { preference.typeface },
                    set: { settings.preference = preference.with(typeface: $0) }
                )) {
                    ForEach(ChatTextPreference.Typeface.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: SettingsLayout.controlWidth)
            }
            SettingRow(label: "Size") {
                PointSizeField(size: Binding(
                    get: { preference.size },
                    set: { settings.preference = preference.with(size: $0) }
                ), range: ChatTextPreference.sizeRange)
            }
            SettingRow(label: "Line height") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Slider(value: Binding(
                        get: { preference.lineHeight },
                        set: { settings.preference = preference.with(lineHeight: ($0 * 10).rounded() / 10) }
                    ), in: ChatTextPreference.lineHeightRange)
                    .frame(width: SettingsLayout.controlWidth - 44)
                    Text(String(format: "%.1f×", preference.lineHeight))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }

            SettingsDivider()

            SettingRow(label: "Theme") {
                Picker("Theme", selection: Binding(
                    get: { preference.theme },
                    set: { settings.preference = preference.with(theme: $0) }
                )) {
                    ForEach(ChatTextPreference.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: SettingsLayout.controlWidth)
            }

            SettingsDivider()

            PreviewBox {
                AnswerText(text: Self.sample)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chatThemed(settings.theme)
            }

            RestoreDefaultsRow(isDefault: preference == .default) {
                settings.preference = .default
            }
        }
    }
}

private extension ChatTextPreference {
    func with(typeface: Typeface? = nil, size: Double? = nil, lineHeight: Double? = nil, theme: Theme? = nil) -> Self {
        ChatTextPreference(typeface: typeface ?? self.typeface, size: size ?? self.size,
                           lineHeight: lineHeight ?? self.lineHeight, theme: theme ?? self.theme)
    }
}
