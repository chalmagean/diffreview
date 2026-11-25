import Foundation

public struct GitError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

public enum DiffMode: Equatable, Sendable {
    /// Working tree (staged + unstaged) vs HEAD, plus untracked files.
    case uncommitted
    /// Committed changes on the current branch since its merge-base with `ref`.
    case base(String)
    /// Already-committed changes, read the way `git` reads the spec:
    /// `<commit>` is that one commit (like `git show`), `A..B` diffs A against B, and
    /// `A...B` diffs B against its merge-base with A. An empty side of a range means HEAD.
    case commits(String)
}

/// Two commits whose difference is under review, as full SHAs. `from` may be the empty tree
/// (the root commit's "parent").
public struct CommitRange: Equatable, Sendable {
    public var from: String
    public var to: String
    /// Just the one commit `to`, compared with its parent.
    public var isSingleCommit: Bool

    public init(from: String, to: String, isSingleCommit: Bool = false) {
        self.from = from
        self.to = to
        self.isSingleCommit = isSingleCommit
    }
}

/// What a review of committed work covers, worded for the top of the review output, so its
/// reader knows which commits it's about and which versions of the files the line numbers mean.
public struct ReviewedCommits: Equatable, Sendable, CustomStringConvertible {
    public var from: String
    public var to: String
    public var isSingleCommit: Bool
    public var subject: String?
    public var count: Int

    public var description: String {
        if isSingleCommit {
            let name = subject.map { "\(to) (\"\($0)\")" } ?? to
            return "Reviewing commit \(name). Line numbers marked (new) are from \(to), (old) from its parent."
        }
        let commits = count == 1 ? "1 commit" : "\(count) commits"
        return "Reviewing \(from)..\(to) (\(commits)). Line numbers marked (new) are from \(to), (old) from \(from)."
    }
}

public struct Git: Sendable {
    public let root: URL
    public let gitDir: URL

    /// Options that make `git diff` output predictable regardless of the user's config.
    static let diffOptions = [
        "--no-color", "--no-ext-diff", "--no-textconv", "--no-relative",
        "--src-prefix=a/", "--dst-prefix=b/", "-M",
    ]

    public init(directory: URL) throws {
        let top = try Self.run(["rev-parse", "--show-toplevel"], in: directory)
        let dir = try Self.run(["rev-parse", "--absolute-git-dir"], in: directory)
        root = URL(fileURLWithPath: Self.trimmed(top), isDirectory: true)
        gitDir = URL(fileURLWithPath: Self.trimmed(dir), isDirectory: true)
    }

    public func loadDiff(mode: DiffMode) throws -> [FileDiff] {
        try loadDiff(mode: mode, range: try commitRange(for: mode))
    }

    /// The diff for `mode`, given the range `commitRange(for: mode)` already resolved, so the
    /// diff and the description of what was reviewed come from the same commits.
    public func loadDiff(mode: DiffMode, range: CommitRange?) throws -> [FileDiff] {
        guard let range else {
            let base = try hasHead() ? "HEAD" : emptyTree()
            let tracked = DiffParser.parse(try git(["diff"] + Self.diffOptions + [base, "--"]))
            return tracked + (try untrackedFiles())
        }
        return DiffParser.parse(try git(["diff"] + Self.diffOptions + [range.from, range.to, "--"]))
    }

    /// The commits a committed-work mode compares, as full SHAs; nil for uncommitted changes.
    public func commitRange(for mode: DiffMode) throws -> CommitRange? {
        switch mode {
        case .uncommitted:
            return nil
        case .base(let ref):
            let (commit, head) = (try resolveCommit(ref), try resolveCommit("HEAD"))
            return CommitRange(from: try mergeBase(commit, head, names: (ref, "HEAD")), to: head)
        case .commits(let spec):
            if let (left, right) = Self.split(spec, on: "...") {
                let (from, to) = (try resolveCommit(left), try resolveCommit(right))
                return CommitRange(from: try mergeBase(from, to, names: (left, right)), to: to)
            }
            if let (left, right) = Self.split(spec, on: "..") {
                return CommitRange(from: try resolveCommit(left), to: try resolveCommit(right))
            }
            let commit = try resolveCommit(spec)
            // The root commit has no parent: compare it with the empty tree.
            let parent = try (try? resolveCommit(commit + "^")) ?? emptyTree()
            return CommitRange(from: parent, to: commit, isSingleCommit: true)
        }
    }

    /// Short names, subject and size of `range`, for telling the review's reader what it covers.
    public func reviewedCommits(_ range: CommitRange) throws -> ReviewedCommits {
        let short = { (sha: String) in Self.trimmed(try self.git(["rev-parse", "--short", sha])) }
        let subject = range.isSingleCommit
            ? Self.trimmed(try git(["log", "-1", "--format=%s", range.to]))
            : nil
        let count = range.isSingleCommit
            ? 1
            : Int(Self.trimmed(try git(["rev-list", "--count", "\(range.from)..\(range.to)"]))) ?? 0
        return ReviewedCommits(from: try short(range.from), to: try short(range.to),
                               isSingleCommit: range.isSingleCommit, subject: subject, count: count)
    }

    /// Splits a range like `A..B` into its sides, with an empty side meaning HEAD.
    static func split(_ spec: String, on separator: String) -> (String, String)? {
        guard let r = spec.range(of: separator) else { return nil }
        let left = String(spec[..<r.lowerBound])
        let right = String(spec[r.upperBound...])
        return (left.isEmpty ? "HEAD" : left, right.isEmpty ? "HEAD" : right)
    }

    func resolveCommit(_ ref: String) throws -> String {
        guard !ref.isEmpty,
              let commit = try? Self.trimmed(git(["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"])),
              !commit.isEmpty else {
            throw GitError(message: "Unknown ref '\(ref)'")
        }
        return commit
    }

    func mergeBase(_ a: String, _ b: String, names: (String, String)) throws -> String {
        do {
            return Self.trimmed(try git(["merge-base", a, b]))
        } catch {
            throw GitError(message: "No common ancestor between '\(names.0)' and '\(names.1)'")
        }
    }


    func hasHead() throws -> Bool {
        (try? git(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])) != nil
    }

    func emptyTree() throws -> String {
        Self.trimmed(try git(["hash-object", "-t", "tree", "/dev/null"]))
    }

    func untrackedFiles() throws -> [FileDiff] {
        let listing = try git(["ls-files", "--others", "--exclude-standard", "-z"])
        // Entries ending in "/" are nested repositories; there is nothing to diff in them.
        let paths = listing.split(separator: "\0").map(String.init).filter { !$0.hasSuffix("/") }
        guard !paths.isEmpty else { return [] }

        let results = Results(count: paths.count)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let path = paths[i]
            // Read from disk; git only for a file that can't be read that way.
            if let file = UntrackedFile.diff(path: path, root: root) {
                results.set(i, file)
                return
            }
            let output = (try? git(["diff"] + Self.diffOptions + ["--no-index", "--", "/dev/null", path],
                                   allowedExitCodes: [0, 1])) ?? ""
            var file = DiffParser.parse(output).first ?? FileDiff(oldPath: nil, newPath: path, status: .added)
            file.oldPath = nil
            file.newPath = path
            file.status = .added
            file.isUntracked = true
            results.set(i, file)
        }
        return results.values.compactMap { $0 }
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [FileDiff?]
        init(count: Int) { values = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ v: FileDiff) {
            lock.lock()
            values[i] = v
            lock.unlock()
        }
    }

    func git(_ args: [String], allowedExitCodes: Set<Int32> = [0]) throws -> String {
        try Self.run(args, in: root, allowedExitCodes: allowedExitCodes)
    }

    static func run(_ args: [String], in directory: URL, allowedExitCodes: Set<Int32> = [0]) throws -> String {
        // The pipes' file handles are autoreleased: without a pool of its own, a caller on a
        // worker thread (diffing thousands of untracked files) keeps them all open until it
        // finishes, and past the system's limit every further launch fails.
        try autoreleasepool { try runOnce(args, in: directory, allowedExitCodes: allowedExitCodes) }
    }

    private static func runOnce(_ args: [String], in directory: URL, allowedExitCodes: Set<Int32>) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "core.quotePath=false"] + args
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0" // don't take index.lock while the user keeps working
        env["LC_ALL"] = "C"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Closed as soon as they're done with, rather than whenever the handles are freed.
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        do {
            try process.run()
        } catch {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            throw GitError(message: "Could not run git: \(error.localizedDescription)")
        }
        // Drain stderr concurrently so a chatty git can't block on a full pipe while we read stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard allowedExitCodes.contains(process.terminationStatus) else {
            let msg = trimmed(String(decoding: errData, as: UTF8.self))
            throw GitError(message: msg.isEmpty ? "git \(args.first ?? "") failed (\(process.terminationStatus))" : msg)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
