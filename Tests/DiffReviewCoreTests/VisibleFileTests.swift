import Testing
@testable import DiffReviewCore

@Suite("VisibleFile")
struct VisibleFileTests {
    @Test func nothingTrackedMeansNoCurrentFile() {
        #expect(VisibleFile.current(tops: [:], threshold: 50) == nil)
    }

    @Test func picksTheLastFileWhoseTopHasReachedTheThreshold() {
        let tops: [Int: Double] = [2: -900, 3: -100, 4: 30, 5: 400]
        #expect(VisibleFile.current(tops: tops, threshold: 50) == 4)
    }

    @Test func aTopExactlyAtTheThresholdCounts() {
        #expect(VisibleFile.current(tops: [0: -10, 1: 50], threshold: 50) == 1)
    }

    @Test func whenEveryTrackedTopIsBelowTheThresholdThePreviousFileIsCurrent() {
        // File 6's top row scrolled away (no longer tracked) while its lines fill the view.
        #expect(VisibleFile.current(tops: [7: 300, 8: 900], threshold: 50) == 6)
    }

    @Test func theFirstFileIsCurrentAtTheTopOfTheDiff() {
        #expect(VisibleFile.current(tops: [0: 0, 1: 600], threshold: 50) == 0)
        #expect(VisibleFile.current(tops: [0: 120, 1: 600], threshold: 50) == 0)
    }
}
