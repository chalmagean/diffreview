import Testing
@testable import DiffReviewCore

@Suite("FileDiff.startsCollapsed")
struct StartsCollapsedTests {
    private func file(_ status: FileStatus, lines: Int) -> FileDiff {
        let kind: LineKind = status == .deleted ? .deletion : .addition
        let body = (0..<lines).map { DiffLine(kind: kind, text: "x", oldNumber: $0 + 1, newNumber: $0 + 1) }
        let path: String? = "a.rb"
        return FileDiff(oldPath: status == .added ? nil : path, newPath: status == .deleted ? nil : path,
                        status: status, hunks: [Hunk(oldStart: 1, oldCount: lines, newStart: 1, newCount: lines,
                                                     lines: body)])
    }

    @Test func anOrdinaryFileStartsExpanded() {
        #expect(!file(.modified, lines: 40).startsCollapsed)
        #expect(!file(.added, lines: 40).startsCollapsed)
    }

    @Test func aDeletedFileStartsCollapsed() {
        #expect(file(.deleted, lines: 3).startsCollapsed)
    }

    @Test func aHugeFileStartsCollapsed() {
        #expect(file(.modified, lines: FileDiff.autoCollapseLineCount + 1).startsCollapsed)
        #expect(!file(.modified, lines: FileDiff.autoCollapseLineCount).startsCollapsed)
    }
}
