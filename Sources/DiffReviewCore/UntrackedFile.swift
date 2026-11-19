import Foundation

/// The diff of an untracked file, read straight from disk: the whole file, added. It's what
/// `git diff --no-index /dev/null <path>` shows, without starting a git process per file
/// (thousands of them took half a minute).
public enum UntrackedFile {
    /// Git calls a file binary when its first 8000 bytes hold a NUL.
    static let binaryCheckLength = 8000

    /// nil when the file can't be read (it vanished, isn't a regular file or link, or isn't
    /// readable): ask git then.
    public static func diff(path: String, root: URL) -> FileDiff? {
        let fullPath = root.appendingPathComponent(path).path
        var info = stat()
        guard lstat(fullPath, &info) == 0 else { return nil }

        let data: Data
        let mode: String
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            // Git shows a link as its target, with no newline.
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: fullPath) else { return nil }
            data = Data(target.utf8)
            mode = "120000"
        case S_IFREG:
            guard let contents = FileManager.default.contents(atPath: fullPath) else { return nil }
            data = contents
            mode = info.st_mode & S_IXUSR != 0 ? "100755" : "100644"
        default:
            return nil
        }

        var file = FileDiff(oldPath: nil, newPath: path, status: .added, isUntracked: true, newMode: mode)
        if data.prefix(binaryCheckLength).contains(0) {
            file.isBinary = true
            return file
        }
        guard !data.isEmpty else { return file }

        let lines = DiffParser.splitLines(String(decoding: data, as: UTF8.self))
        var hunk = Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count)
        hunk.lines = lines.enumerated().map { DiffLine(kind: .addition, text: $1, oldNumber: nil, newNumber: $0 + 1) }
        if data.last != UInt8(ascii: "\n") { hunk.lines[hunk.lines.count - 1].noNewlineAtEnd = true }
        file.hunks = [hunk]
        return file
    }
}
