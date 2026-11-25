import Foundation
import Testing
@testable import DiffReviewCore

@Suite("ChatTextPreference")
struct ChatTextPreferenceTests {
    /// A throwaway defaults domain so tests never touch the real preferences.
    func makeDefaults() -> UserDefaults {
        let name = "diffreview.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("defaults to the system typeface at 15 pt, 1.5 line height, standard theme")
    func defaults() {
        let pref = ChatTextPreference.load(from: makeDefaults())
        #expect(pref == .default)
        #expect(pref.typeface == .system)
        #expect(pref.size == 15)
        #expect(pref.lineHeight == 1.5)
        #expect(pref.theme == .standard)
    }

    @Test("round-trips through user defaults")
    func roundTrip() {
        let defaults = makeDefaults()
        let pref = ChatTextPreference(typeface: .serif, size: 17, lineHeight: 1.7, theme: .paper)
        pref.save(to: defaults)
        #expect(ChatTextPreference.load(from: defaults) == pref)
    }

    @Test("size and line height are clamped into range")
    func clamps() {
        let small = ChatTextPreference(typeface: .system, size: 2, lineHeight: 0.5, theme: .standard)
        #expect(small.size == ChatTextPreference.sizeRange.lowerBound)
        #expect(small.lineHeight == ChatTextPreference.lineHeightRange.lowerBound)
        let big = ChatTextPreference(typeface: .system, size: 99, lineHeight: 9, theme: .standard)
        #expect(big.size == ChatTextPreference.sizeRange.upperBound)
        #expect(big.lineHeight == ChatTextPreference.lineHeightRange.upperBound)
    }

    @Test("unknown or missing stored values fall back to the defaults")
    func fallbacks() {
        let defaults = makeDefaults()
        defaults.set("comic", forKey: ChatTextPreference.typefaceKey)
        defaults.set("neon", forKey: ChatTextPreference.themeKey)
        defaults.set(0.0, forKey: ChatTextPreference.sizeKey)
        #expect(ChatTextPreference.load(from: defaults) == .default)
    }

    @Test("line height becomes the extra space between lines, over the font's own 1.2")
    func lineSpacing() {
        let pref = ChatTextPreference(typeface: .system, size: 15, lineHeight: 1.5, theme: .standard)
        #expect(abs(pref.lineSpacing - 4.5) < 0.001)
        let tight = ChatTextPreference(typeface: .system, size: 15, lineHeight: 1.2, theme: .standard)
        #expect(tight.lineSpacing == 0)
    }

    @Test("paragraphs are spaced in proportion to the text")
    func paragraphSpacing() {
        #expect(ChatTextPreference(typeface: .system, size: 20, lineHeight: 1.5, theme: .standard).paragraphSpacing == 14)
        #expect(ChatTextPreference.default.paragraphSpacing == 10.5)
    }

    @Test("every typeface and theme has a title for the settings menu")
    func titles() {
        #expect(ChatTextPreference.Typeface.allCases.map(\.title) == ["System", "Serif", "Rounded", "Monospaced"])
        #expect(ChatTextPreference.Theme.allCases.map(\.title) == ["Standard", "Paper", "Night", "High contrast"])
    }
}
