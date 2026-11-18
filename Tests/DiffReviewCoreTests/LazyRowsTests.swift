import Testing
@testable import DiffReviewCore

@Suite("RowChunks")
struct RowChunksTests {
    @Test func noRowsMeansNoChunks() {
        #expect(RowChunks.ranges(count: 0, size: 50).isEmpty)
    }

    @Test func fewerRowsThanAChunkMakeOneChunk() {
        #expect(RowChunks.ranges(count: 7, size: 50) == [0..<7])
    }

    @Test func rowsSplitIntoFullChunksPlusTheRemainder() {
        #expect(RowChunks.ranges(count: 120, size: 50) == [0..<50, 50..<100, 100..<120])
    }

    @Test func anExactMultipleHasNoEmptyTrailingChunk() {
        #expect(RowChunks.ranges(count: 100, size: 50) == [0..<50, 50..<100])
    }
}

@Suite("ScrollSettle")
struct ScrollSettleTests {
    @Test func notSettledWhileTheTargetIsntBuilt() {
        #expect(!ScrollSettle.isSettled(top: nil, previousTop: nil))
        #expect(!ScrollSettle.isSettled(top: nil, previousTop: 0))
    }

    @Test func settledOnceTheTargetIsAtTheTop() {
        #expect(ScrollSettle.isSettled(top: 0.4, previousTop: nil))
        #expect(ScrollSettle.isSettled(top: -0.4, previousTop: 900))
    }

    @Test func notSettledWhileTheTargetIsStillMoving() {
        #expect(!ScrollSettle.isSettled(top: 300, previousTop: nil))
        #expect(!ScrollSettle.isSettled(top: 300, previousTop: 1200))
    }

    @Test func settledWhenTheTargetStopsShortOfTheTop() {
        // The last file of a diff can't scroll all the way up.
        #expect(ScrollSettle.isSettled(top: 300, previousTop: 300.2))
    }
}
