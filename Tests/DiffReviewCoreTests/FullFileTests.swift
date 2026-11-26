import Foundation
import Testing
@testable import DiffReviewCore

/// The whole file, shown in place of its diff: every line of the new version, numbered on
/// both sides like the diff's context lines, with the lines the diff added marked as additions.
@Suite("Full file view")
struct FullFileTests {
    private func diff(_ old: String, _ new: String) throws -> FileDiff {
        let repo = try TempRepo()
        try repo.write("f.txt", old)
        try repo.commitAll()
        try repo.write("f.txt", new)
        return try #require(try Git(directory: repo.url).loadDiff(mode: .uncommitted).first)
    }

    @Test("lines outside the hunks get old numbers shifted by the lines added above them")
    func numbering() throws {
        let old = (1...20).map { "l\($0)" }.joined(separator: "\n") + "\n"
        var newLines = (1...20).map { "l\($0)" }
        newLines.insert("added", at: 2)
        let new = newLines.joined(separator: "\n") + "\n"
        let lines = FullFile.lines(of: new, diff: try diff(old, new))

        #expect(lines.count == 21)
        #expect(lines.map(\.text) == newLines)
        #expect(lines.map(\.newNumber) == (1...21).map { $0 })

        // Before the change, old and new numbers agree.
        #expect(lines[0].kind == .context && lines[0].oldNumber == 1)
        // The added line has no old number.
        #expect(lines[2].kind == .addition && lines[2].oldNumber == nil)
        // Far below the hunk, old numbers are one behind.
        #expect(lines[20].kind == .context && lines[20].oldNumber == 20)
    }

    @Test("lines a diff removed don't appear; the ones after them are numbered past them")
    func deletion() throws {
        let old = (1...20).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let newLines = (1...20).map { "l\($0)" }.filter { $0 != "l3" && $0 != "l4" }
        let new = newLines.joined(separator: "\n") + "\n"
        let lines = FullFile.lines(of: new, diff: try diff(old, new))

        #expect(lines.map(\.text) == newLines)
        #expect(lines.allSatisfy { $0.kind == .context })
        #expect(lines.last?.newNumber == 18 && lines.last?.oldNumber == 20)
    }

    @Test("every line of a new file is an addition")
    func newFile() {
        var hunk = Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 2)
        hunk.lines = [DiffLine(kind: .addition, text: "a", oldNumber: nil, newNumber: 1),
                      DiffLine(kind: .addition, text: "b", oldNumber: nil, newNumber: 2)]
        let file = FileDiff(oldPath: nil, newPath: "n.txt", status: .added, hunks: [hunk])
        let lines = FullFile.lines(of: "a\nb\n", diff: file)
        #expect(lines.map(\.kind) == [.addition, .addition])
        #expect(lines.map(\.oldNumber) == [nil, nil])
    }

    @Test("a missing final newline is marked on the last line")
    func noNewline() {
        let file = FileDiff(oldPath: "x", newPath: "x")
        let lines = FullFile.lines(of: "a\nb", diff: file)
        #expect(lines.map(\.noNewlineAtEnd) == [false, true])
        #expect(FullFile.lines(of: "a\n", diff: file).last?.noNewlineAtEnd == false)
    }

    @Test("an anchor of a line in both views names the same line")
    func anchorsMatchTheDiff() throws {
        let old = (1...10).map { "l\($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "l5\n", with: "five\n")
        let file = try diff(old, new)
        let full = Set(FullFile.lines(of: new, diff: file).compactMap(\.anchor))
        let diffNewSide = file.allLines.filter { $0.kind != .deletion }.compactMap(\.anchor)
        #expect(diffNewSide.allSatisfy(full.contains))
    }
}

@Suite("Reading the new version of a file", .serialized)
struct NewContentTests {
    @Test("uncommitted changes read the working tree")
    func workingTree() throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "one\n")
        try repo.commitAll()
        try repo.write("a.txt", "two\n")
        let git = try Git(directory: repo.url)
        let file = try #require(try git.loadDiff(mode: .uncommitted).first)
        #expect(try git.newContent(of: file, range: nil) == "two\n")
    }

    @Test("committed work reads the file at the range's end, not the working tree")
    func atCommit() throws {
        let repo = try TempRepo()
        try repo.write("dir/a b.txt", "one\n")
        try repo.commitAll()
        try repo.write("dir/a b.txt", "two\n")
        try repo.commitAll()
        try repo.write("dir/a b.txt", "uncommitted\n")
        let git = try Git(directory: repo.url)
        let range = try #require(try git.commitRange(for: .commits("HEAD")))
        let file = try #require(try git.loadDiff(mode: .commits("HEAD"), range: range).first)
        #expect(try git.newContent(of: file, range: range) == "two\n")
    }

    @Test("a deleted file has no new version")
    func deleted() throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "one\n")
        try repo.commitAll()
        try repo.git("rm", "-q", "a.txt")
        let git = try Git(directory: repo.url)
        let file = try #require(try git.loadDiff(mode: .uncommitted).first)
        #expect(throws: GitError.self) { try git.newContent(of: file, range: nil) }
    }
}
