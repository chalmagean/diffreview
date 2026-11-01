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

    var path: String { diff.path }

    init(id: Int, diff: FileDiff) {
        self.id = id
        self.diff = diff
        var lines: [DiffLine] = []
        var rows: [DisplayRow] = []
        for hunk in diff.hunks {
            rows.append(DisplayRow(id: rows.count, kind: .hunkHeader(hunk.header)))
            for line in hunk.lines {
                rows.append(DisplayRow(id: rows.count, kind: .line(lines.count)))
                lines.append(line)
            }
        }
        self.lines = lines
        self.rows = rows
        language = Language.fenceName(forPath: diff.path)
        let maxLine = diff.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        gutterDigits = max(3, String(maxLine).count)
        anchors = Set(lines.compactMap(\.anchor))
    }
}

/// A contiguous range of selected lines in one file (indices into `DisplayFile.lines`).
struct LineSelection: Equatable {
    var fileID: Int
    var anchor: Int
    var head: Int
    var range: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }
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
    var composerText = ""
    var fileComposerID: Int?
    var fileComposerText = ""
    var editingID: UUID?
    var editText = ""
    var scrollRequest: ScrollRequest?

    struct ScrollRequest: Equatable {
        let fileID: Int
        let token = UUID()
    }

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

    func isSelected(fileID: Int, lineIndex: Int) -> Bool {
        guard let sel = selection, sel.fileID == fileID else { return false }
        return sel.range.contains(lineIndex)
    }

    func composerLine(fileID: Int) -> Int? {
        guard let sel = selection, sel.fileID == fileID else { return nil }
        return sel.range.upperBound
    }

    func cancelComposer() {
        selection = nil
        composerText = ""
    }

    func addLineComment() {
        guard let sel = selection, let file = files.first(where: { $0.id == sel.fileID }) else { return }
        let body = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let lines = Array(file.lines[sel.range])
        draft.comments.append(ReviewComment.line(path: file.path, lines: lines, body: body))
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

    func reveal(fileID: Int) {
        scrollRequest = ScrollRequest(fileID: fileID)
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
