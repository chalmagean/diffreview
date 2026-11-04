import Foundation

/// The parts of a deleted and an added line that differ, as UTF-16 ranges into each line's
/// text (without a trailing carriage return), ready to lay over the drawn code.
public struct InlineChanges: Equatable, Sendable {
    public var old: [NSRange]
    public var new: [NSRange]
}

/// Word-level changes between paired lines, like GitHub's darker inline highlights.
public enum InlineDiff {
    /// Lines sharing less than this fraction of the longer line's text are treated as
    /// rewritten: marking nearly everything would be noise.
    static let minimumShared = 0.4
    /// The token LCS is quadratic; longer lines (minified code, data) are left unmarked.
    static let maxTokens = 400

    public static func changes(old: String, new: String) -> InlineChanges? {
        let a = tokens(old), b = tokens(new)
        guard a.count <= maxTokens, b.count <= maxTokens else { return nil }
        let (keptA, keptB) = commonTokens(a.map(\.text), b.map(\.text))
        let shared = zip(a, keptA).reduce(0) { $0 + ($1.1 ? $1.0.length : 0) }
        let longest = max(a.reduce(0) { $0 + $1.length }, b.reduce(0) { $0 + $1.length })
        if longest > 0, Double(shared) / Double(longest) < minimumShared { return nil }
        return InlineChanges(old: changedRanges(a, keptA), new: changedRanges(b, keptB))
    }

    /// Marks for a hunk's lines, keyed by index into `lines`. Each run of deletions is paired,
    /// line by line, with the run of additions right after it; lines without a partner, or
    /// whose partner is too different, get none.
    public static func emphasis(for lines: [DiffLine]) -> [Int: [NSRange]] {
        var marks: [Int: [NSRange]] = [:]
        var i = 0
        while i < lines.count {
            guard lines[i].kind == .deletion else { i += 1; continue }
            var additionsStart = i
            while additionsStart < lines.count, lines[additionsStart].kind == .deletion { additionsStart += 1 }
            var end = additionsStart
            while end < lines.count, lines[end].kind == .addition { end += 1 }
            for k in 0..<min(additionsStart - i, end - additionsStart) {
                let (o, n) = (i + k, additionsStart + k)
                guard let change = changes(old: lines[o].text, new: lines[n].text) else { continue }
                if !change.old.isEmpty { marks[o] = change.old }
                if !change.new.isEmpty { marks[n] = change.new }
            }
            i = end
        }
        return marks
    }

    // MARK: Tokens

    struct Token {
        var text: String
        var location: Int
        var length: Int
    }

    private enum Class { case word, space, other }

    private static func charClass(_ c: Character) -> Class {
        if c.isLetter || c.isNumber || c == "_" { return .word }
        if c.isWhitespace { return .space }
        return .other
    }

    /// Runs of word characters, runs of whitespace, and single punctuation characters.
    static func tokens(_ line: String) -> [Token] {
        let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
        var result: [Token] = []
        var offset = 0
        var current: (text: String, location: Int, length: Int, cls: Class)?
        for c in text {
            let cls = charClass(c)
            let width = c.utf16.count
            if var run = current, run.cls == cls, cls != .other {
                run.text.append(c)
                run.length += width
                current = run
            } else {
                if let run = current { result.append(Token(text: run.text, location: run.location, length: run.length)) }
                current = (String(c), offset, width, cls)
            }
            offset += width
        }
        if let run = current { result.append(Token(text: run.text, location: run.location, length: run.length)) }
        return result
    }

    /// Which tokens of each side belong to a longest common subsequence.
    private static func commonTokens(_ a: [String], _ b: [String]) -> ([Bool], [Bool]) {
        let n = a.count, m = b.count
        // suffix[i * (m + 1) + j] = LCS length of a[i...] and b[j...]
        var suffix = [Int](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                suffix[i * (m + 1) + j] = a[i] == b[j]
                    ? suffix[(i + 1) * (m + 1) + j + 1] + 1
                    : max(suffix[(i + 1) * (m + 1) + j], suffix[i * (m + 1) + j + 1])
            }
        }
        var keptA = [Bool](repeating: false, count: n)
        var keptB = [Bool](repeating: false, count: m)
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                keptA[i] = true; keptB[j] = true
                i += 1; j += 1
            } else if suffix[(i + 1) * (m + 1) + j] >= suffix[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (keptA, keptB)
    }

    /// The tokens not kept, with neighbouring ones merged into one range.
    private static func changedRanges(_ tokens: [Token], _ kept: [Bool]) -> [NSRange] {
        var ranges: [NSRange] = []
        for (token, isKept) in zip(tokens, kept) where !isKept {
            if let last = ranges.last, NSMaxRange(last) == token.location {
                ranges[ranges.count - 1].length += token.length
            } else {
                ranges.append(NSRange(location: token.location, length: token.length))
            }
        }
        return ranges
    }
}
