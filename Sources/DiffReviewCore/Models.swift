import Foundation

public enum LineKind: String, Codable, Sendable {
    case context, addition, deletion
}

public struct DiffLine: Equatable, Hashable, Sendable {
    public var kind: LineKind
    /// Line content without the leading +/-/space marker and without the trailing newline.
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    /// Set when git emitted "\ No newline at end of file" after this line.
    public var noNewlineAtEnd: Bool

    public init(kind: LineKind, text: String, oldNumber: Int?, newNumber: Int?, noNewlineAtEnd: Bool = false) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.noNewlineAtEnd = noNewlineAtEnd
    }

    /// The anchor identifying this row in the diff: deletions live on the old side, everything else on the new side.
    public var anchor: LineAnchor? {
        switch kind {
        case .deletion: return oldNumber.map { LineAnchor(side: .old, line: $0) }
        case .addition, .context: return newNumber.map { LineAnchor(side: .new, line: $0) }
        }
    }
}

public struct Hunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Text after the closing "@@" (usually the enclosing function), trimmed.
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String = "", lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = lines
    }

    public var header: String {
        var s = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if !section.isEmpty { s += " " + section }
        return s
    }
}

public enum FileStatus: String, Sendable {
    case modified, added, deleted, renamed, copied

    public var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        }
    }
}

public struct FileDiff: Equatable, Sendable {
    /// nil when the file was created.
    public var oldPath: String?
    /// nil when the file was deleted.
    public var newPath: String?
    public var status: FileStatus
    public var isBinary: Bool
    public var isUntracked: Bool
    public var oldMode: String?
    public var newMode: String?
    public var similarity: Int?
    public var hunks: [Hunk]

    public init(oldPath: String?, newPath: String?, status: FileStatus = .modified, isBinary: Bool = false,
                isUntracked: Bool = false, oldMode: String? = nil, newMode: String? = nil,
                similarity: Int? = nil, hunks: [Hunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.isBinary = isBinary
        self.isUntracked = isUntracked
        self.oldMode = oldMode
        self.newMode = newMode
        self.similarity = similarity
        self.hunks = hunks
    }

    /// The path comments are keyed by: the new path, or the old one for deletions.
    public var path: String { newPath ?? oldPath ?? "" }

    public var displayPath: String {
        if (status == .renamed || status == .copied), let o = oldPath, let n = newPath, o != n {
            return "\(o) → \(n)"
        }
        return path
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
    public var allLines: [DiffLine] { hunks.flatMap(\.lines) }
}
