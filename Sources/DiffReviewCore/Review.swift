import Foundation

public enum Side: String, Codable, Sendable {
    case old, new
}

/// Identifies a row in a file's diff: deletions by old line number, other rows by new line number.
public struct LineAnchor: Codable, Hashable, Sendable {
    public var side: Side
    public var line: Int

    public init(side: Side, line: Int) {
        self.side = side
        self.line = line
    }
}

public struct SnippetLine: Codable, Equatable, Sendable {
    public var kind: LineKind
    public var text: String

    public init(kind: LineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct ReviewComment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var body: String
    /// Line-range comments only. `side`/`startLine`/`endLine` drive the "Lines 42-45 (new)" label.
    public var side: Side?
    public var startLine: Int?
    public var endLine: Int?
    /// First and last selected rows; the comment is displayed under `endAnchor`.
    public var startAnchor: LineAnchor?
    public var endAnchor: LineAnchor?
    /// The selected lines, captured when the comment was made.
    public var snippet: [SnippetLine]
    /// Set when only part of the lines was selected: the exact text the comment is about.
    public var selectedText: String?
    public var createdAt: Date

    public var isFileLevel: Bool { endAnchor == nil }

    public static func file(path: String, body: String) -> ReviewComment {
        ReviewComment(id: UUID(), path: path, body: body, side: nil, startLine: nil, endLine: nil,
                      startAnchor: nil, endAnchor: nil, snippet: [], selectedText: nil, createdAt: Date())
    }

    /// A comment on a contiguous range of diff rows. If any selected row exists on the new side the
    /// comment refers to new-side line numbers; a selection of only deletions refers to the old side.
    public static func line(path: String, lines: [DiffLine], body: String, selectedText: String? = nil) -> ReviewComment {
        let side: Side = lines.allSatisfy { $0.kind == .deletion } ? .old : .new
        let numbers = lines.compactMap { side == .new ? $0.newNumber : $0.oldNumber }
        return ReviewComment(
            id: UUID(), path: path, body: body, side: side,
            startLine: numbers.first, endLine: numbers.last,
            startAnchor: lines.first?.anchor, endAnchor: lines.last?.anchor,
            snippet: lines.map { SnippetLine(kind: $0.kind, text: $0.text) },
            selectedText: selectedText,
            createdAt: Date())
    }

    public var rangeLabel: String {
        guard let side, let start = startLine else { return "File" }
        let end = endLine ?? start
        return start == end ? "Line \(start) (\(side.rawValue))" : "Lines \(start)-\(end) (\(side.rawValue))"
    }
}

public enum SelectedText {
    /// The text between `startOffset` in the first line and `endOffset` in the last (UTF-16 offsets,
    /// as used by the diff view's text layout; a trailing CR is ignored). Returns nil when the
    /// selection is empty or covers the lines completely, i.e. when it's just a line comment.
    public static func extract(lines: [String], startOffset: Int, endOffset: Int) -> String? {
        let texts = lines.map { line -> NSString in
            var t = line
            if t.hasSuffix("\r") { t.removeLast() }
            return t as NSString
        }
        guard let first = texts.first, let last = texts.last else { return nil }
        let start = min(max(0, startOffset), first.length)
        let end = min(max(0, endOffset), last.length)
        if start == 0 && end == last.length { return nil }
        if texts.count == 1 {
            guard end > start else { return nil }
            return first.substring(with: NSRange(location: start, length: end - start))
        }
        var parts = [first.substring(from: start)]
        parts += texts.dropFirst().dropLast().map { $0 as String }
        parts.append(last.substring(to: end))
        return parts.joined(separator: "\n")
    }
}

public struct ReviewDraft: Codable, Equatable, Sendable {
    public var version = 1
    public var summary = ""
    public var comments: [ReviewComment] = []

    public init(summary: String = "", comments: [ReviewComment] = []) {
        self.summary = summary
        self.comments = comments
    }

    public var isEmpty: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && comments.isEmpty
    }
}
