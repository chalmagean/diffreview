import Foundation

/// A changed file shown whole instead of as its diff: every line of the new version.
public enum FullFile {
    /// The lines of `text` (the file's new version), numbered like the diff's context lines:
    /// each has its new number and, unless the diff added it, the number it had in the old
    /// version. Lines the diff added are additions. A line's anchor is the one the same line
    /// has in the diff, so comments show on it in both views.
    public static func lines(of text: String, diff: FileDiff) -> [DiffLine] {
        let texts = DiffParser.splitLines(text)
        // What the diff says about the lines it shows, by new line number.
        var inHunks: [Int: DiffLine] = [:]
        // Where each hunk's new side ends, with how far old numbers are from new after it.
        var shifts: [(afterNew: Int, offset: Int)] = []
        for hunk in diff.hunks {
            for line in hunk.lines where line.kind != .deletion {
                if let n = line.newNumber { inHunks[n] = line }
            }
            shifts.append((hunk.newStart + hunk.newCount, (hunk.oldStart + hunk.oldCount) - (hunk.newStart + hunk.newCount)))
        }

        var shift = 0
        var nextShift = 0
        var lines = texts.enumerated().map { index, text -> DiffLine in
            let number = index + 1
            while nextShift < shifts.count, number >= shifts[nextShift].afterNew {
                shift = shifts[nextShift].offset
                nextShift += 1
            }
            if let known = inHunks[number] {
                return DiffLine(kind: known.kind, text: text, oldNumber: known.oldNumber, newNumber: number)
            }
            return DiffLine(kind: .context, text: text, oldNumber: number + shift, newNumber: number)
        }
        if !lines.isEmpty, !text.hasSuffix("\n") { lines[lines.count - 1].noNewlineAtEnd = true }
        return lines
    }
}

extension Git {
    /// The file's new version, the one its diff leads to: from the working tree for
    /// uncommitted changes, otherwise as committed at the end of `range`.
    /// Throws when there's no new version (a deleted file) or it can't be read.
    public func newContent(of file: FileDiff, range: CommitRange?) throws -> String {
        guard let path = file.newPath else { throw GitError(message: "\(file.path) was deleted") }
        guard let range else {
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path) else {
                throw GitError(message: "Could not read \(path)")
            }
            return String(decoding: data, as: UTF8.self)
        }
        return try git(["cat-file", "blob", "\(range.to):\(path)"])
    }
}
