import Foundation
import Testing
@testable import DiffReviewCore

@Suite("FontPreference")
struct FontPreferenceTests {
    /// A throwaway defaults domain so tests never touch the real preferences.
    func makeDefaults() -> UserDefaults {
        let name = "diffreview.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToSystemMonospacedAt12pt() {
        let pref = FontPreference.load(from: makeDefaults())
        #expect(pref.family == nil)
        #expect(pref.size == 12)
        #expect(pref == .default)
    }

    @Test func roundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        FontPreference(family: "Menlo", size: 15).save(to: defaults)
        let loaded = FontPreference.load(from: defaults)
        #expect(loaded.family == "Menlo")
        #expect(loaded.size == 15)
    }

    @Test func savingTheSystemFontClearsAStoredFamily() {
        let defaults = makeDefaults()
        FontPreference(family: "Menlo", size: 14).save(to: defaults)
        FontPreference(family: nil, size: 14).save(to: defaults)
        #expect(FontPreference.load(from: defaults).family == nil)
    }

    @Test func blankFamilyMeansSystemFont() {
        #expect(FontPreference(family: "", size: 12).family == nil)
        #expect(FontPreference(family: "   ", size: 12).family == nil)
    }

    @Test func clampsSizeIntoTheAllowedRange() {
        #expect(FontPreference(family: nil, size: 2).size == FontPreference.sizeRange.lowerBound)
        #expect(FontPreference(family: nil, size: 500).size == FontPreference.sizeRange.upperBound)
    }

    @Test func ignoresOutOfRangeOrMissingStoredSize() {
        let defaults = makeDefaults()
        defaults.set(0.0, forKey: FontPreference.sizeKey)
        #expect(FontPreference.load(from: defaults).size == FontPreference.default.size)
        defaults.set(99.0, forKey: FontPreference.sizeKey)
        #expect(FontPreference.load(from: defaults).size == FontPreference.sizeRange.upperBound)
    }
}
