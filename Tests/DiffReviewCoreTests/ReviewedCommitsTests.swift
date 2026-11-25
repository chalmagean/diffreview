import Testing
@testable import DiffReviewCore

@Suite("ReviewedCommits")
struct ReviewedCommitsTests {
    @Test("a single commit is named with its subject")
    func singleCommit() {
        let reviewed = ReviewedCommits(from: "80e8115", to: "170ec1b", isSingleCommit: true,
                                       subject: "Set the Dock icon", count: 1)
        #expect(reviewed.description == """
            Reviewing commit 170ec1b ("Set the Dock icon"). \
            Line numbers marked (new) are from 170ec1b, (old) from its parent.
            """)
    }

    @Test("a range is named by its ends and how many commits it holds")
    func range() {
        let reviewed = ReviewedCommits(from: "a1", to: "b2", isSingleCommit: false, subject: nil, count: 3)
        #expect(reviewed.description == """
            Reviewing a1..b2 (3 commits). \
            Line numbers marked (new) are from b2, (old) from a1.
            """)
        let one = ReviewedCommits(from: "a1", to: "b2", isSingleCommit: false, subject: nil, count: 1)
        #expect(one.description.hasPrefix("Reviewing a1..b2 (1 commit). "))
    }
}
