import Foundation
import Testing
@testable import DiffReviewCore

/// Untracked files are read straight from disk rather than diffed by a git process each
/// (thousands of processes took half a minute). What's read must match what git shows.
@Suite("Untracked files", .serialized)
struct UntrackedFileTests {
    /// What `git diff --no-index /dev/null <path>` shows for the file, parsed.
    private func gitsDiff(_ path: String, in repo: TempRepo) throws -> FileDiff {
        let git = try Git(directory: repo.url)
        let output = try git.git(["diff"] + Git.diffOptions + ["--no-index", "--", "/dev/null", path],
                                 allowedExitCodes: [0, 1])
        var file = try #require(DiffParser.parse(output).first)
        file.oldPath = nil
        file.newPath = path
        file.status = .added
        file.isUntracked = true
        return file
    }

    private func read(_ path: String, in repo: TempRepo) -> FileDiff? {
        UntrackedFile.diff(path: path, root: repo.url)
    }

    @Test("matches git for text files of every shape", arguments: [
        ("plain.rb", "class A\n  def x; end\nend\n"),
        ("no_newline.txt", "one\ntwo"),
        ("single_line.txt", "only\n"),
        ("single_no_newline.txt", "only"),
        ("blank_lines.txt", "\n\n\n"),
        ("crlf.txt", "one\r\ntwo\r\n"),
        ("unicode.md", "héllo — 世界 🎉\nnext\n"),
        ("trailing_blank.txt", "a\n\n"),
        ("tabs.go", "\tfunc x() {\n\t\treturn\n\t}\n"),
    ])
    func text(path: String, content: String) throws {
        let repo = try TempRepo()
        try repo.write(path, content)
        #expect(read(path, in: repo) == (try gitsDiff(path, in: repo)))
    }

    @Test("an empty file has no lines")
    func empty() throws {
        let repo = try TempRepo()
        try repo.write("empty.txt", "")
        let file = try #require(read("empty.txt", in: repo))
        #expect(file.hunks.isEmpty && !file.isBinary && file.status == .added && file.isUntracked)
        #expect(file.newMode == "100644")
    }

    @Test("a file with a NUL byte is binary, like git says")
    func binary() throws {
        let repo = try TempRepo()
        try repo.write("blob.bin", Data([0x50, 0x4b, 0, 1, 2, 255]))
        let file = try #require(read("blob.bin", in: repo))
        #expect(file.isBinary && file.hunks.isEmpty)
        #expect(try gitsDiff("blob.bin", in: repo).isBinary)
    }

    @Test("an executable file has mode 100755")
    func executable() throws {
        let repo = try TempRepo()
        try repo.write("run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: repo.url.appendingPathComponent("run.sh").path)
        #expect(read("run.sh", in: repo) == (try gitsDiff("run.sh", in: repo)))
        #expect(read("run.sh", in: repo)?.newMode == "100755")
    }

    @Test("a symlink shows where it points, like git")
    func symlink() throws {
        let repo = try TempRepo()
        try repo.write("target.txt", "x\n")
        try FileManager.default.createSymbolicLink(atPath: repo.url.appendingPathComponent("link").path,
                                                   withDestinationPath: "target.txt")
        #expect(read("link", in: repo) == (try gitsDiff("link", in: repo)))
    }

    @Test("a file that can't be read gives nil, so git is asked instead")
    func missing() throws {
        let repo = try TempRepo()
        #expect(read("nope.txt", in: repo) == nil)
    }

    @Test("loading thousands of untracked files is quick")
    func many() throws {
        let repo = try TempRepo()
        for i in 0..<3000 { try repo.write("d\(i % 30)/f\(i).rb", "line \(i)\n") }
        let start = Date()
        let files = try Git(directory: repo.url).loadDiff(mode: .uncommitted)
        #expect(files.count == 3000)
        #expect(files.allSatisfy { $0.hunks.first?.lines.first?.text.hasPrefix("line ") == true })
        #expect(Date().timeIntervalSince(start) < 2, "took \(Date().timeIntervalSince(start))s")
    }
}
