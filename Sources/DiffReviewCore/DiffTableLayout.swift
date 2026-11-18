/// One row of the diff table.
public enum DiffTableRow: Hashable, Sendable {
    /// The file's header, pinned to the top while its rows scroll by.
    case fileHeader(file: Int)
    /// File comments, the file composer and notices; shown even when the file is collapsed.
    case fileTop(file: Int)
    /// One of the file's display rows (a hunk header or a diff line).
    case row(file: Int, index: Int)

    public var file: Int {
        switch self {
        case .fileHeader(let file), .fileTop(let file), .row(let file, _): return file
        }
    }
}

/// The diff as one flat list of table rows: every file's header and top row, then its rows
/// unless it's collapsed. Files are identified by their index.
public struct DiffTableLayout: Sendable {
    public let rows: [DiffTableRow]
    /// Table row of each file's header.
    private let starts: [Int]
    private let shownCounts: [Int]

    public init(rowCounts: [Int], collapsed: Set<Int>) {
        var rows: [DiffTableRow] = []
        var starts: [Int] = []
        var shownCounts: [Int] = []
        rows.reserveCapacity(rowCounts.reduce(2 * rowCounts.count, +))
        for (file, count) in rowCounts.enumerated() {
            starts.append(rows.count)
            rows.append(.fileHeader(file: file))
            rows.append(.fileTop(file: file))
            let shown = collapsed.contains(file) ? 0 : count
            shownCounts.append(shown)
            for index in 0..<shown { rows.append(.row(file: file, index: index)) }
        }
        self.rows = rows
        self.starts = starts
        self.shownCounts = shownCounts
    }

    public func headerRow(ofFile file: Int) -> Int? {
        starts.indices.contains(file) ? starts[file] : nil
    }

    /// The table row showing `row`, or nil when it isn't shown.
    public func index(of row: DiffTableRow) -> Int? {
        guard let start = headerRow(ofFile: row.file) else { return nil }
        switch row {
        case .fileHeader: return start
        case .fileTop: return start + 1
        case .row(let file, let index):
            return (0..<shownCounts[file]).contains(index) ? start + 2 + index : nil
        }
    }
}

/// How wide a line of code is in a monospaced font, in character cells, so most lines'
/// heights can be known without laying their text out.
public enum CodeColumns {
    /// - Returns: the columns the text spans, with tabs advancing to the next multiple of
    ///   `tabWidth`; nil when that depends on the font (anything but printable ASCII and tabs).
    public static func width(of text: String, tabWidth: Int = 4) -> Int? {
        var columns = 0
        for byte in text.utf8 {
            switch byte {
            case 0x09: columns += tabWidth - columns % tabWidth
            case 0x20...0x7E: columns += 1
            default: return nil
            }
        }
        return columns
    }
}
