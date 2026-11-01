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
        switch mode {
        case .uncommitted:
            let base = try hasHead() ? "HEAD" : emptyTree()
            let tracked = DiffParser.parse(try git(["diff"] + Self.diffOptions + [base, "--"]))
            return tracked + (try untrackedFiles())
        case .base(let ref):
            guard let commit = try? Self.trimmed(git(["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"])),
                  !commit.isEmpty else {
                throw GitError(message: "Unknown ref '\(ref)'")
            }
            let mergeBase: String
            do {
                mergeBase = Self.trimmed(try git(["merge-base", commit, "HEAD"]))
            } catch {
                throw GitError(message: "No common ancestor between '\(ref)' and HEAD")
            }
            return DiffParser.parse(try git(["diff"] + Self.diffOptions + [mergeBase, "HEAD", "--"]))
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

        do {
            try process.run()
        } catch {
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
