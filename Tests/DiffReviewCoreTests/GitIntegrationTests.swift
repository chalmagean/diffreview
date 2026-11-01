import Foundation
import Testing
@testable import DiffReviewCore

/// A throwaway git repository in the temp directory.
final class TempRepo {
    let url: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffreview-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // git reports real paths (/private/var/...), so resolve the /var symlink up front.
        url = URL(fileURLWithPath: realpath(raw.path, nil).map { String(cString: $0) } ?? raw.path)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ content: String) throws {
        try write(path, Data(content.utf8))
    }

    func write(_ path: String, _ data: Data) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = url
        // Ignore the developer's global/system git config (hooks, signing, templates...).
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw GitError(message: "git \(args.joined(separator: " ")) failed")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func commitAll(_ message: String = "c") throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }
}

@Suite("Git integration", .serialized)
struct GitIntegrationTests {
    @Test("uncommitted mode includes tracked changes and untracked files")
    func uncommitted() throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        try repo.write(".gitignore", "ignored.txt\n")
        try repo.commitAll()

        try repo.write("a.txt", "one\n2\nthree\n")
        try repo.write("sub dir/new.txt", "fresh\nfile")
        try repo.write("empty.txt", "")
        try repo.write("ignored.txt", "nope\n")
        try repo.write("blob.bin", Data([0, 1, 2, 0, 255]))
        try repo.git("add", "a.txt") // staged changes count as uncommitted too

        let git = try Git(directory: repo.url)
        #expect(git.root.path == repo.url.path)
        let files = try git.loadDiff(mode: .uncommitted)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        #expect(Set(byPath.keys) == ["a.txt", "sub dir/new.txt", "empty.txt", "blob.bin"])

        let a = try #require(byPath["a.txt"])
        #expect(a.isUntracked == false)
        #expect(a.status == .modified)
        #expect(a.additions == 1 && a.deletions == 1)

        let new = try #require(byPath["sub dir/new.txt"])
        #expect(new.isUntracked)
        #expect(new.status == .added)
        #expect(new.oldPath == nil)
        #expect(new.hunks.first?.lines.map(\.text) == ["fresh", "file"])
        #expect(new.hunks.first?.lines.last?.noNewlineAtEnd == true)

        let empty = try #require(byPath["empty.txt"])
        #expect(empty.isUntracked && empty.status == .added && empty.hunks.isEmpty)

        let bin = try #require(byPath["blob.bin"])
        #expect(bin.isUntracked && bin.isBinary)

        // Tracked files come first, untracked after, each sorted by path.
        #expect(files.first?.path == "a.txt")
    }

    @Test("uncommitted mode works in a repository without commits")
    func unbornHead() throws {
        let repo = try TempRepo()
        try repo.write("staged.txt", "s\n")
        try repo.git("add", "staged.txt")
        try repo.write("loose.txt", "l\n")

        let files = try Git(directory: repo.url).loadDiff(mode: .uncommitted)
        #expect(files.map(\.path) == ["staged.txt", "loose.txt"])
        #expect(files[0].status == .added && !files[0].isUntracked)
        #expect(files[1].isUntracked)
    }

    @Test("base mode diffs the branch against the merge-base")
    func baseMode() throws {
        let repo = try TempRepo()
        try repo.write("a.txt", "base\n")
        try repo.commitAll()
        try repo.git("checkout", "-q", "-b", "feature")
        try repo.write("a.txt", "feature\n")
        try repo.git("mv", "a.txt", "b.txt")
        try repo.commitAll()
        // A later commit on main must not show up.
        try repo.git("checkout", "-q", "main")
        try repo.write("main-only.txt", "m\n")
        try repo.commitAll()
        try repo.git("checkout", "-q", "feature")
        // Uncommitted work is not part of the branch comparison.
        try repo.write("scratch.txt", "x\n")

        let files = try Git(directory: repo.url).loadDiff(mode: .base("main"))
        // A full rewrite plus move is too dissimilar to be a rename: git reports delete + add.
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
        #expect(files.map(\.status) == [.deleted, .added])
    }

    @Test("base mode detects renames")
    func baseRename() throws {
        let repo = try TempRepo()
        let body = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try repo.write("old.txt", body)
        try repo.commitAll()
        try repo.git("checkout", "-q", "-b", "feature")
        try repo.git("mv", "old.txt", "new.txt")
        try repo.commitAll()

        let files = try Git(directory: repo.url).loadDiff(mode: .base("main"))
        #expect(files.count == 1)
        #expect(files[0].status == .renamed)
        #expect(files[0].oldPath == "old.txt" && files[0].newPath == "new.txt")
    }

    @Test("unknown base ref throws")
    func badRef() throws {
        let repo = try TempRepo()
        try repo.write("a", "a\n")
        try repo.commitAll()
        #expect(throws: GitError.self) {
            try Git(directory: repo.url).loadDiff(mode: .base("does-not-exist"))
        }
    }

    @Test("outside a repository throws")
    func notARepo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: GitError.self) { try Git(directory: dir) }
    }

    @Test("works from a subdirectory and finds the git dir")
    func subdirectory() throws {
        let repo = try TempRepo()
        try repo.write("x/y/z.txt", "z\n")
        try repo.commitAll()
        try repo.write("x/y/z.txt", "zz\n")
        let git = try Git(directory: repo.url.appendingPathComponent("x/y"))
        #expect(git.root.path == repo.url.path)
        #expect(git.gitDir.path == repo.url.appendingPathComponent(".git").path)
        #expect(try git.loadDiff(mode: .uncommitted).map(\.path) == ["x/y/z.txt"])
    }
}

@Suite("Arguments")
struct ArgumentsTests {
    @Test func parsing() throws {
        #expect(try Arguments.parse([]) == Arguments(mode: .uncommitted))
        #expect(try Arguments.parse(["--base", "main"]) == Arguments(mode: .base("main")))
        #expect(try Arguments.parse(["--base=origin/dev"]) == Arguments(mode: .base("origin/dev")))
        #expect(try Arguments.parse(["-h"]).help)
        #expect(throws: ArgumentError.self) { try Arguments.parse(["--base"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["--wat"]) }
        #expect(throws: ArgumentError.self) { try Arguments.parse(["-b", "main"]) }
    }
}
