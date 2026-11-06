import AppKit
import DiffReviewCore
import Observation

/// One row in a file's diff view.
struct DisplayRow: Identifiable {
    enum Kind {
        case hunkHeader(String)
        /// Index into `DisplayFile.lines`.
        case line(Int)
    }
    let id: Int
    let kind: Kind
}

/// A FileDiff prepared for display: flattened lines and rows computed once.
struct DisplayFile: Identifiable {
    let id: Int
    let diff: FileDiff
    let lines: [DiffLine]
    let rows: [DisplayRow]
    let language: String
    let gutterDigits: Int
    let anchors: Set<LineAnchor>
    /// Word-level changes per line index: what differs from the paired deleted/added line.
    let emphasis: [Int: [NSRange]]

    var path: String { diff.path }
    /// Identity of this file's section in the diff. A String, so a scroll to it can't match a
    /// `DisplayRow` (whose ids are Ints numbered within each file).
    var sectionID: String { Self.sectionID(id) }
    static func sectionID(_ fileID: Int) -> String { "file-section-\(fileID)" }

    init(id: Int, diff: FileDiff) {
        self.id = id
        self.diff = diff
        var lines: [DiffLine] = []
        var rows: [DisplayRow] = []
        var emphasis: [Int: [NSRange]] = [:]
        for hunk in diff.hunks {
            rows.append(DisplayRow(id: rows.count, kind: .hunkHeader(hunk.header)))
            for (index, ranges) in InlineDiff.emphasis(for: hunk.lines) {
                emphasis[lines.count + index] = ranges
            }
            for line in hunk.lines {
                rows.append(DisplayRow(id: rows.count, kind: .line(lines.count)))
                lines.append(line)
            }
        }
        self.lines = lines
        self.rows = rows
        self.emphasis = emphasis
        language = Language.fenceName(forPath: diff.path)
        let maxLine = diff.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        gutterDigits = max(3, String(maxLine).count)
        anchors = Set(lines.compactMap(\.anchor))
    }
}

/// A contiguous range of selected lines in one file (indices into `DisplayFile.lines`).
/// With offsets set it's a character selection: from `anchorOffset` in line `anchor` to
/// `headOffset` in line `head` (UTF-16 offsets into the line text, without a trailing CR).
struct LineSelection: Equatable {
    var fileID: Int
    var anchor: Int
    var head: Int
    var anchorOffset: Int?
    var headOffset: Int?

    var range: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }
    var isCharacterSelection: Bool { anchorOffset != nil && headOffset != nil }

    /// Start and end positions in document order (character selections only).
    var ordered: (start: (line: Int, offset: Int), end: (line: Int, offset: Int))? {
        guard let a = anchorOffset, let h = headOffset else { return nil }
        let first = (line: anchor, offset: a), second = (line: head, offset: h)
        return (first.line, first.offset) <= (second.line, second.offset) ? (first, second) : (second, first)
    }
}

/// The part of one line covered by a character selection.
struct LineHighlight: Equatable {
    var range: NSRange
    /// The selection continues onto the next line.
    var continues: Bool
}

@MainActor
@Observable
final class ReviewStore {
    /// Files with more lines than this start collapsed so huge diffs open instantly.
    static let autoCollapseLineCount = 1500

    let files: [DisplayFile]
    let title: String
    let repoName: String

    var draft: ReviewDraft {
        didSet {
            rebuildIndex()
            scheduleSave()
        }
    }

    var collapsed: Set<Int>
    var selection: LineSelection?
    /// A text selection is being dragged out; the composer waits until it's done.
    var isDraggingSelection = false
    var composerText = ""
    var fileComposerID: Int?
    var fileComposerText = ""
    var editingID: UUID?
    var editText = ""
    var scrollRequest: ScrollRequest?
    /// The file the diff is scrolled to, highlighted in the sidebar.
    private(set) var visibleFileID: Int?

    struct ScrollRequest: Equatable {
        let fileID: Int
        let token = UUID()
    }

    /// file id → y of its first row in the diff viewport, for the files currently built.
    @ObservationIgnored private var fileTops: [Int: Double] = [:]
    /// A jump from the sidebar keeps its file highlighted while the scroll settles, even
    /// when that file can't reach the top (e.g. the last file of the diff).
    @ObservationIgnored private var followScrollAfter = Date.distantPast
    /// Just below the pinned file header.
    private static let visibleFileThreshold: Double = 48

    /// path → anchor → comments displayed under that row.
    private(set) var lineComments: [String: [LineAnchor: [ReviewComment]]] = [:]
    /// path → file-level comments, plus line comments whose rows no longer exist in the diff.
    private(set) var fileComments: [String: [ReviewComment]] = [:]
    private(set) var commentCounts: [String: Int] = [:]

    @ObservationIgnored let draftStore: DraftStore
    @ObservationIgnored let highlighter: SyntaxHighlighter = PlainHighlighter()
    @ObservationIgnored var onSubmit: ((String) -> Void)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private let filesByPath: [String: DisplayFile]

    init(files: [FileDiff], title: String, repoName: String, draftStore: DraftStore) {
        let display = files.enumerated().map { DisplayFile(id: $0.offset, diff: $0.element) }
        self.files = display
        self.title = title
        self.repoName = repoName
        self.draftStore = draftStore
        self.draft = draftStore.load() ?? ReviewDraft()
        self.filesByPath = Dictionary(display.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        self.collapsed = Set(display.filter { $0.lines.count > Self.autoCollapseLineCount }.map(\.id))
        rebuildIndex()
    }

    // MARK: - Derived

    var totalAdditions: Int { files.reduce(0) { $0 + $1.diff.additions } }
    var totalDeletions: Int { files.reduce(0) { $0 + $1.diff.deletions } }

    /// Comments on files that aren't part of the current diff (restored from an older draft).
    var staleComments: [ReviewComment] {
        draft.comments.filter { filesByPath[$0.path] == nil }
    }

    func isOutdated(_ comment: ReviewComment) -> Bool {
        guard let anchor = comment.endAnchor else { return false }
        return filesByPath[comment.path]?.anchors.contains(anchor) != true
    }

    private func rebuildIndex() {
        var lines: [String: [LineAnchor: [ReviewComment]]] = [:]
        var fileLevel: [String: [ReviewComment]] = [:]
        var counts: [String: Int] = [:]
        for c in draft.comments {
            counts[c.path, default: 0] += 1
            if let anchor = c.endAnchor, !isOutdated(c) {
                lines[c.path, default: [:]][anchor, default: []].append(c)
            } else {
                fileLevel[c.path, default: []].append(c)
            }
        }
        lineComments = lines
        fileComments = fileLevel
        commentCounts = counts
    }

    // MARK: - Line selection & composer

    func click(fileID: Int, lineIndex: Int, extend: Bool) {
        editingID = nil
        if extend, var sel = selection, sel.fileID == fileID {
            sel.head = lineIndex
            selection = sel
        } else {
            selection = LineSelection(fileID: fileID, anchor: lineIndex, head: lineIndex)
        }
    }

    /// Whole-line selection highlight (character selections highlight text instead).
    func isSelected(fileID: Int, lineIndex: Int) -> Bool {
        guard let sel = selection, sel.fileID == fileID, !sel.isCharacterSelection else { return false }
        return sel.range.contains(lineIndex)
    }

    func highlight(fileID: Int, lineIndex: Int) -> LineHighlight? {
        guard let sel = selection, sel.fileID == fileID, sel.range.contains(lineIndex),
              let ordered = sel.ordered,
              let file = files.first(where: { $0.id == fileID }) else { return nil }
        let length = (codeText(file.lines[lineIndex].text) as NSString).length
        let (start, end) = ordered
        let from = lineIndex == start.line ? min(start.offset, length) : 0
        let to = lineIndex == end.line ? min(end.offset, length) : length
        return LineHighlight(range: NSRange(location: from, length: max(0, to - from)),
                             continues: lineIndex != end.line)
    }

    func composerLine(fileID: Int) -> Int? {
        guard !isDraggingSelection, let sel = selection, sel.fileID == fileID else { return nil }
        return sel.range.upperBound
    }

    func beginTextSelection(fileID: Int, lineIndex: Int, offset: Int) {
        editingID = nil
        isDraggingSelection = true
        selection = LineSelection(fileID: fileID, anchor: lineIndex, head: lineIndex,
                                  anchorOffset: offset, headOffset: offset)
    }

    func extendTextSelection(fileID: Int, lineIndex: Int, offset: Int) {
        guard var sel = selection, sel.fileID == fileID, sel.isCharacterSelection else { return }
        guard sel.head != lineIndex || sel.headOffset != offset else { return }
        sel.head = lineIndex
        sel.headOffset = offset
        selection = sel
    }

    /// An empty selection is dropped; one that covers whole lines becomes a line selection.
    func endTextSelection() {
        isDraggingSelection = false
        guard var sel = selection, sel.isCharacterSelection else { return }
        if partialText(sel) == nil {
            if sel.anchor == sel.head { selection = nil; return }
            sel.anchorOffset = nil
            sel.headOffset = nil
            selection = sel
        }
    }

    func partialText(_ sel: LineSelection) -> String? {
        guard let ordered = sel.ordered,
              let file = files.first(where: { $0.id == sel.fileID }) else { return nil }
        return SelectedText.extract(lines: file.lines[sel.range].map(\.text),
                                    startOffset: ordered.start.offset, endOffset: ordered.end.offset)
    }

    func cancelComposer() {
        selection = nil
        isDraggingSelection = false
        composerText = ""
    }

    func addLineComment() {
        guard let sel = selection, let file = files.first(where: { $0.id == sel.fileID }) else { return }
        let body = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let lines = Array(file.lines[sel.range])
        draft.comments.append(ReviewComment.line(path: file.path, lines: lines, body: body,
                                                 selectedText: partialText(sel)))
        cancelComposer()
    }

    func openFileComposer(fileID: Int) {
        fileComposerID = fileID
        collapsed.remove(fileID)
    }

    func cancelFileComposer() {
        fileComposerID = nil
        fileComposerText = ""
    }

    func addFileComment() {
        guard let id = fileComposerID, let file = files.first(where: { $0.id == id }) else { return }
        let body = fileComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft.comments.append(ReviewComment.file(path: file.path, body: body))
        cancelFileComposer()
    }

    func beginEdit(_ comment: ReviewComment) {
        editText = comment.body
        editingID = comment.id
    }

    func cancelEdit() {
        editingID = nil
        editText = ""
    }

    func commitEdit() {
        guard let id = editingID else { return }
        update(id, body: editText)
        editText = ""
    }

    func update(_ id: UUID, body: String) {
        guard let i = draft.comments.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft.comments.remove(at: i)
        } else {
            draft.comments[i].body = trimmed
        }
        editingID = nil
    }

    func delete(_ id: UUID) {
        draft.comments.removeAll { $0.id == id }
        if editingID == id { editingID = nil }
    }

    func discardStaleComments() {
        let stale = Set(staleComments.map(\.id))
        draft.comments.removeAll { stale.contains($0.id) }
    }

    // MARK: - Files

    func toggleCollapsed(_ id: Int) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    func setAllCollapsed(_ value: Bool) {
        collapsed = value ? Set(files.map(\.id)) : []
    }

    /// Whether a file's first row is currently built in the diff (only then can it be scrolled to).
    func isFileTopBuilt(_ fileID: Int) -> Bool { fileTops[fileID] != nil }

    func reveal(fileID: Int) {
        visibleFileID = fileID
        // Covers the re-issued scrolls in DiffView.
        followScrollAfter = Date().addingTimeInterval(0.6)
        scrollRequest = ScrollRequest(fileID: fileID)
    }

    /// A file's first row moved in the diff viewport (`nil` once it's no longer built).
    func fileTopMoved(_ fileID: Int, to y: Double?) {
        fileTops[fileID] = y
        guard Date() >= followScrollAfter,
              let current = VisibleFile.current(tops: fileTops, threshold: Self.visibleFileThreshold),
              current != visibleFileID else { return }
        visibleFileID = current
    }

    // MARK: - Persistence & submit

    /// Text typed into an open composer but not yet added is folded in so it is never lost.
    private func commitPendingComposers() {
        if selection != nil, !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addLineComment()
        }
        if fileComposerID != nil, !fileComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addFileComment()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persist() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Called when the window closes without submitting.
    func saveNow() {
        commitPendingComposers()
        persist()
    }

    private func persist() {
        saveWork?.cancel()
        saveWork = nil
        if draft.isEmpty {
            draftStore.clear()
        } else {
            do {
                try draftStore.save(draft)
            } catch {
                FileHandle.standardError.write(Data("diffreview: could not save draft: \(error)\n".utf8))
            }
        }
    }

    func submit() {
        commitPendingComposers()
        saveWork?.cancel()
        let markdown = MarkdownRenderer.render(draft: draft, files: files.map(\.diff))
        draftStore.clear()
        onSubmit?(markdown)
    }
}

/// A diff line's text as laid out in the code view (selection offsets index into this).
func codeText(_ text: String) -> String {
    text.hasSuffix("\r") ? String(text.dropLast()) : text
}
