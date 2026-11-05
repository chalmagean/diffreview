import Foundation
import Testing
@testable import DiffReviewCore

@Suite("AppearancePreference")
struct AppearancePreferenceTests {
    /// A throwaway defaults domain so tests never touch the real preferences.
    func makeDefaults() -> UserDefaults {
        let name = "diffreview.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToFollowingTheSystem() {
        #expect(AppearancePreference.load(from: makeDefaults()) == .system)
        #expect(AppearancePreference.default == .system)
    }

    @Test(arguments: AppearancePreference.allCases)
    func roundTripsThroughUserDefaults(_ preference: AppearancePreference) {
        let defaults = makeDefaults()
        preference.save(to: defaults)
        #expect(AppearancePreference.load(from: defaults) == preference)
    }

    @Test func savingSystemClearsTheStoredValue() {
        let defaults = makeDefaults()
        AppearancePreference.dark.save(to: defaults)
        AppearancePreference.system.save(to: defaults)
        #expect(defaults.object(forKey: AppearancePreference.key) == nil)
    }

    @Test func unknownStoredValueFallsBackToSystem() {
        let defaults = makeDefaults()
        defaults.set("sepia", forKey: AppearancePreference.key)
        #expect(AppearancePreference.load(from: defaults) == .system)
    }

    @Test func listsChoicesInMenuOrder() {
        #expect(AppearancePreference.allCases == [.system, .light, .dark])
        #expect(AppearancePreference.allCases.map(\.title) == ["System", "Light", "Dark"])
    }
}
