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
    public var createdAt: Date

    public var isFileLevel: Bool { endAnchor == nil }

    public static func file(path: String, body: String) -> ReviewComment {
        ReviewComment(id: UUID(), path: path, body: body, side: nil, startLine: nil, endLine: nil,
                      startAnchor: nil, endAnchor: nil, snippet: [], createdAt: Date())
    }

    /// A comment on a contiguous range of diff rows. If any selected row exists on the new side the
    /// comment refers to new-side line numbers; a selection of only deletions refers to the old side.
    public static func line(path: String, lines: [DiffLine], body: String) -> ReviewComment {
        let side: Side = lines.allSatisfy { $0.kind == .deletion } ? .old : .new
        let numbers = lines.compactMap { side == .new ? $0.newNumber : $0.oldNumber }
        return ReviewComment(
            id: UUID(), path: path, body: body, side: side,
            startLine: numbers.first, endLine: numbers.last,
            startAnchor: lines.first?.anchor, endAnchor: lines.last?.anchor,
            snippet: lines.map { SnippetLine(kind: $0.kind, text: $0.text) },
            createdAt: Date())
    }

    public var rangeLabel: String {
        guard let side, let start = startLine else { return "File" }
        let end = endLine ?? start
        return start == end ? "Line \(start) (\(side.rawValue))" : "Lines \(start)-\(end) (\(side.rawValue))"
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
