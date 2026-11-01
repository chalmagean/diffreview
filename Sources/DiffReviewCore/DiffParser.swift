import Foundation

/// Parses `git diff` unified output into `FileDiff` values.
///
/// Hunk bodies are consumed using the line counts from each `@@` header, so content
/// lines such as `--- foo` inside a hunk are never mistaken for file headers.
public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var builder = Builder()
        for line in splitLines(text) {
            builder.consume(line)
        }
        builder.finishFile()
        return builder.files
    }

    /// Splits on "\n" only (Swift treats "\r\n" as one Character, so `split(separator: "\n")` would not).
    static func splitLines(_ text: String) -> [String] {
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private struct PendingFile {
        var oldPath: String?
        var newPath: String?
        var isNew = false
        var isDeleted = false
        var isRename = false
        var isCopy = false
        var isBinary = false
        var oldMode: String?
        var newMode: String?
        var similarity: Int?
        var hunks: [Hunk] = []
        var sawMinusDevNull = false
        var sawPlusDevNull = false

        func build() -> FileDiff {
            var status: FileStatus = .modified
            var oldPath = self.oldPath
            var newPath = self.newPath
            if isNew || sawMinusDevNull {
                status = .added
                oldPath = nil
            } else if isDeleted || sawPlusDevNull {
                status = .deleted
                newPath = nil
            } else if isRename {
                status = .renamed
            } else if isCopy {
                status = .copied
            }
            return FileDiff(oldPath: oldPath, newPath: newPath, status: status, isBinary: isBinary,
                            oldMode: oldMode, newMode: newMode, similarity: similarity, hunks: hunks)
        }
    }

    private struct Builder {
        var files: [FileDiff] = []
        var current: PendingFile?
        var hunk: Hunk?
        var oldRemaining = 0
        var newRemaining = 0
        var oldLine = 0
        var newLine = 0
        var skippingBinaryPatch = false

        mutating func consume(_ line: String) {
            // Inside a hunk body: the counts tell us exactly how many lines belong to it.
            if hunk != nil, oldRemaining > 0 || newRemaining > 0 {
                consumeHunkLine(line)
                return
            }
            if line.hasPrefix("\\") {
                markNoNewline()
                return
            }
            if line.hasPrefix("diff --git ") {
                finishFile()
                var file = PendingFile()
                if let (a, b) = parseGitHeaderPaths(String(line.dropFirst("diff --git ".count))) {
                    file.oldPath = a
                    file.newPath = b
                }
                current = file
                return
            }
            guard current != nil else { return } // preamble or unknown text
            if skippingBinaryPatch { return }
            if line.hasPrefix("@@") {
                startHunk(line)
                return
            }
            parseHeaderLine(line)
        }

        mutating func parseHeaderLine(_ line: String) {
            func value(after prefix: String) -> String? {
                line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
            }
            if let v = value(after: "--- ") {
                if let p = parseFileLinePath(v) { current?.oldPath = stripPrefix(p, "a/") } else { current?.sawMinusDevNull = true }
            } else if let v = value(after: "+++ ") {
                if let p = parseFileLinePath(v) { current?.newPath = stripPrefix(p, "b/") } else { current?.sawPlusDevNull = true }
            } else if let v = value(after: "new file mode ") {
                current?.isNew = true
                current?.newMode = v
            } else if let v = value(after: "deleted file mode ") {
                current?.isDeleted = true
                current?.oldMode = v
            } else if let v = value(after: "old mode ") {
                current?.oldMode = v
            } else if let v = value(after: "new mode ") {
                current?.newMode = v
            } else if let v = value(after: "rename from ") {
                current?.isRename = true
                current?.oldPath = unquoteIfNeeded(v)
            } else if let v = value(after: "rename to ") {
                current?.isRename = true
                current?.newPath = unquoteIfNeeded(v)
            } else if let v = value(after: "copy from ") {
                current?.isCopy = true
                current?.oldPath = unquoteIfNeeded(v)
            } else if let v = value(after: "copy to ") {
                current?.isCopy = true
                current?.newPath = unquoteIfNeeded(v)
            } else if let v = value(after: "similarity index ") {
                current?.similarity = Int(v.trimmingCharacters(in: CharacterSet(charactersIn: "%")))
            } else if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
                current?.isBinary = true
            } else if line == "GIT binary patch" {
                current?.isBinary = true
                skippingBinaryPatch = true
            }
            // "index ...", "dissimilarity index ..." and anything else: ignored.
        }

        mutating func startHunk(_ line: String) {
            finishHunk()
            guard let parsed = parseHunkHeader(line) else { return }
            hunk = parsed
            oldRemaining = parsed.oldCount
            newRemaining = parsed.newCount
            oldLine = parsed.oldStart
            newLine = parsed.newStart
        }

        mutating func consumeHunkLine(_ line: String) {
            let marker = line.first
            let text = line.isEmpty ? "" : String(line.dropFirst())
            switch marker {
            case "+":
                hunk?.lines.append(DiffLine(kind: .addition, text: text, oldNumber: nil, newNumber: newLine))
                newLine += 1
                newRemaining -= 1
            case "-":
                hunk?.lines.append(DiffLine(kind: .deletion, text: text, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
                oldRemaining -= 1
            case "\\":
                markNoNewline()
            default:
                // " " context, or an empty line from tools that strip trailing whitespace.
                let content = marker == " " ? text : line
                hunk?.lines.append(DiffLine(kind: .context, text: content, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
                oldRemaining -= 1
                newRemaining -= 1
            }
        }

        mutating func markNoNewline() {
            if hunk != nil, let last = hunk!.lines.indices.last {
                hunk!.lines[last].noNewlineAtEnd = true
            } else if var file = current, let h = file.hunks.indices.last, let l = file.hunks[h].lines.indices.last {
                file.hunks[h].lines[l].noNewlineAtEnd = true
                current = file
            }
        }

        mutating func finishHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
            oldRemaining = 0
            newRemaining = 0
        }

        mutating func finishFile() {
            finishHunk()
            if let file = current { files.append(file.build()) }
            current = nil
            skippingBinaryPatch = false
        }
    }

    // MARK: - Header helpers

    /// "@@ -a[,b] +c[,d] @@ section"
    static func parseHunkHeader(_ line: String) -> Hunk? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        guard parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int)? {
            let nums = s.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(nums[0]) else { return nil }
            let count = nums.count > 1 ? Int(nums[1]) : 1
            guard let count else { return nil }
            return (start, count)
        }
        guard let (os, oc) = range(parts[1]), let (ns, nc) = range(parts[2]) else { return nil }
        var section = ""
        if parts.count == 4 {
            let rest = parts[3]
            if rest.hasPrefix("@@") {
                section = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            }
        }
        return Hunk(oldStart: os, oldCount: oc, newStart: ns, newCount: nc, section: section)
    }

    /// Paths from "a/x b/y" (possibly C-quoted). Used as a fallback when no ---/+++ or rename lines follow.
    static func parseGitHeaderPaths(_ s: String) -> (String, String)? {
        if s.hasPrefix("\"") {
            guard let (a, rest) = readQuoted(Substring(s)) else { return nil }
            let r = rest.drop(while: { $0 == " " })
            let b = r.hasPrefix("\"") ? readQuoted(r)?.0 : String(r)
            guard let b else { return nil }
            return (stripPrefix(a, "a/"), stripPrefix(b, "b/"))
        }
        if let q = s.range(of: " \"") {
            let a = String(s[..<q.lowerBound])
            guard let (b, _) = readQuoted(s[s.index(after: q.lowerBound)...]) else { return nil }
            return (stripPrefix(a, "a/"), stripPrefix(b, "b/"))
        }
        // Unquoted: when the two names are equal the string is "a/P b/P", which handles spaces in P.
        let chars = Array(s)
        if chars.count >= 7, chars.count % 2 == 1 {
            let len = (chars.count - 5) / 2
            let first = String(chars[0..<(2 + len)])
            let second = String(chars[(3 + len)...])
            if chars[2 + len] == " ", first.hasPrefix("a/"), second.hasPrefix("b/"),
               first.dropFirst(2) == second.dropFirst(2) {
                let p = String(first.dropFirst(2))
                return (p, p)
            }
        }
        guard let r = s.range(of: " b/") else { return nil }
        return (stripPrefix(String(s[..<r.lowerBound]), "a/"), String(s[r.upperBound...]))
    }

    /// Path from a "--- " / "+++ " line; nil for /dev/null.
    static func parseFileLinePath(_ v: String) -> String? {
        let path: String
        if v.hasPrefix("\"") {
            path = readQuoted(Substring(v))?.0 ?? v
        } else if let tab = v.firstIndex(of: "\t") {
            path = String(v[..<tab])
        } else {
            path = v
        }
        return path == "/dev/null" ? nil : path
    }

    static func stripPrefix(_ s: String, _ prefix: String) -> String {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : s
    }

    static func unquoteIfNeeded(_ s: String) -> String {
        s.hasPrefix("\"") ? (readQuoted(Substring(s))?.0 ?? s) : s
    }

    /// Reads a C-style quoted string as produced by git (core.quotePath), returning it and the remainder.
    static func readQuoted(_ s: Substring) -> (String, Substring)? {
        guard s.first == "\"" else { return nil }
        var bytes: [UInt8] = []
        var i = s.utf8.index(after: s.utf8.startIndex)
        let u = s.utf8
        while i < u.endIndex {
            let c = u[i]
            if c == UInt8(ascii: "\"") {
                let rest = Substring(u[u.index(after: i)...])
                return (String(decoding: bytes, as: UTF8.self), rest)
            }
            if c == UInt8(ascii: "\\") {
                i = u.index(after: i)
                guard i < u.endIndex else { return nil }
                let e = u[i]
                switch e {
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "a"): bytes.append(0x07)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "v"): bytes.append(0x0B)
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(e - UInt8(ascii: "0"))
                    var n = 1
                    var j = u.index(after: i)
                    while n < 3, j < u.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(u[j]) {
                        value = value * 8 + Int(u[j] - UInt8(ascii: "0"))
                        i = j
                        j = u.index(after: j)
                        n += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                default: bytes.append(e) // \" and \\ and anything else
                }
            } else {
                bytes.append(c)
            }
            i = u.index(after: i)
        }
        return nil
    }
}
