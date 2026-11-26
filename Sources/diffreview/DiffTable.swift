import AppKit
import DiffReviewCore
import Observation
import SwiftUI

/// The diff as an AppKit table. Unlike a SwiftUI lazy stack, which guesses the height of
/// rows it hasn't built (leaving gaps when it guesses wrong) and walks every row before a
/// target to scroll to it, the table is told each row's height: plain lines by arithmetic,
/// the few rows with comments or composers by measuring them. A jump is then one scroll to
/// a known offset. Each row is still SwiftUI, hosted in a cell.
struct DiffTable: NSViewRepresentable {
    let store: ReviewStore

    func makeCoordinator() -> DiffTableController { DiffTableController(store: store) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// What one table row shows.
struct DiffRowContent: View {
    let store: ReviewStore
    let row: DiffTableRow
    var onHeight: ((CGFloat) -> Void)?

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight?($0) }
            // A reused cell starts fresh (e.g. not still hovered).
            .id(row)
    }

    @ViewBuilder private var content: some View {
        let file = store.shown(row.file)
        switch row {
        case .fileHeader:
            FileHeader(store: store, file: file)
        case .fileTop:
            FileTopRow(store: store, file: file)
        case .row(_, let index):
            switch file.rows[index].kind {
            case .hunkHeader(let header):
                HunkHeaderRow(header: header, digits: file.gutterDigits)
            case .line(let line):
                LineBlock(store: store, file: file, index: line)
            }
        }
    }
}

private struct DiffCell: View {
    let content: DiffRowContent
    var body: some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private final class DiffCellView: NSView {
    let hosting: NSHostingView<DiffCell>

    init(content: DiffRowContent) {
        hosting = NSHostingView(rootView: DiffCell(content: content))
        super.init(frame: .zero)
        // The table sets the size; the hosting view shouldn't add constraints of its own.
        hosting.sizingOptions = []
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // While the window is dragged to a new size, rows keep the width they had: laying
        // every visible row out again on each frame of the drag makes it stutter. They take
        // the new width once the drag ends.
        let width = inLiveResize && hosting.frame.width > 0 ? hosting.frame.width : bounds.width
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsLayout = true
    }
}

/// Draws nothing itself, so the file header's own background shows when it floats.
private final class PlainRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

private final class DiffTableNSView: NSTableView {
    // Rows aren't selectable, so don't draw a focus ring around the table.
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    var onLiveResizeEnd: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onLiveResizeEnd?()
    }
}

@MainActor
final class DiffTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let store: ReviewStore
    /// Each file as shown (its diff or its whole version), read for every row, so kept here
    /// rather than read through the store; replaced when a file switches view.
    private var files: [DisplayFile]
    private var showingFullFile: Set<Int>
    let scrollView = NSScrollView()
    private let tableView = DiffTableNSView()

    private var layout: DiffTableLayout
    private var collapsed: Set<Int>
    /// Nothing is shown until the table has its real width: at width 0 every line would wrap
    /// and be laid out character by character.
    private var ready = false
    /// Row heights, valid at `heightsWidth`: computed, measured, or reported by a cell.
    private var heights: [DiffTableRow: CGFloat] = [:]
    private var heightsWidth: CGFloat = 0
    /// Rows that aren't a bare diff line (comments, composers, notices), with what's in them;
    /// these are measured, and re-measured when what's in them changes.
    private var rich: [DiffTableRow: RichContent] = [:]
    private var metrics: Metrics
    /// Set while the table scrolls itself, so the sidebar keeps the jumped-to file highlighted
    /// even when it can't reach the top (the last files of a diff).
    private var jumping = false
    private var heightNotesPending: IndexSet = []

    init(store: ReviewStore) {
        self.store = store
        let shown = store.files.map { store.shown($0.id) }
        files = shown
        showingFullFile = store.showingFullFile
        collapsed = store.collapsed
        layout = DiffTableLayout(rowCounts: shown.map(\.rows.count), collapsed: store.collapsed)
        metrics = Metrics.measure(store)
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .textBackgroundColor
        tableView.floatsGroupRows = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resized() }
        }
        tableView.onLiveResizeEnd = { [weak self] in self?.resized() }

        rich = richContent()
        observeContent()
        observeScrollRequests()
    }

    // MARK: Data source & delegate

    func numberOfRows(in tableView: NSTableView) -> Int { ready ? layout.rows.count : 0 }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .fileHeader = layout.rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlainRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = layout.rows[row]
        let content = DiffRowContent(store: store, row: entry) { [weak self] height in
            self?.cellReported(height, for: entry)
        }
        let identifier = NSUserInterfaceItemIdentifier(Self.kind(of: entry, in: store))
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DiffCellView {
            cell.hosting.rootView = DiffCell(content: content)
            return cell
        }
        let cell = DiffCellView(content: content)
        cell.identifier = identifier
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let entry = layout.rows[row]
        if let height = heights[entry] { return height }
        // The table asks for every row's height up front: most need no measuring or caching.
        if let height = plainHeight(entry) { return height }
        var height = computeHeight(entry)
        // A row with an invalid height would crash the table.
        if !height.isFinite || height <= 0 { height = metrics.line }
        heights[entry] = height
        return height
    }

    /// Cells are reused only for rows of the same kind, whose views share a structure.
    private static func kind(of entry: DiffTableRow, in store: ReviewStore) -> String {
        switch entry {
        case .fileHeader: return "header"
        case .fileTop: return "top"
        case .row(let file, let index):
            if case .hunkHeader = store.shown(file).rows[index].kind { return "hunk" }
            return "line"
        }
    }

    // MARK: Heights

    private var width: CGFloat { scrollView.contentView.bounds.width }

    /// Each file's room for code at `lineSpaceWidth` in `lineSpaceFont`.
    private var lineSpace: [CGFloat] = []
    private var lineSpaceWidth: CGFloat = -1
    private var lineSpaceFont: NSFont?

    /// The height of a row that's one fixed height: headers, and lines that fit on one line.
    private func plainHeight(_ entry: DiffTableRow) -> CGFloat? {
        guard rich[entry] == nil else { return nil }
        switch entry {
        case .fileHeader: return metrics.fileHeader
        case .fileTop: return metrics.emptyFileTop
        case .row(let fileID, let index):
            guard case .line(let lineIndex) = files[fileID].rows[index].kind else { return metrics.hunkHeader }
            let columns = files[fileID].columns[lineIndex]
            guard metrics.isMonospaced, columns >= 0 else { return nil }
            if lineSpaceWidth != width || lineSpaceFont !== metrics.font {
                lineSpace = files.map { width - gutterTotalWidth($0.gutterDigits) - markerWidth }
                lineSpaceWidth = width
                lineSpaceFont = metrics.font
            }
            let available = lineSpace[fileID] - (files[fileID].lines[lineIndex].noNewlineAtEnd ? 16 : 0)
            return CGFloat(columns) * metrics.advance + 2 < available ? metrics.line : nil
        }
    }

    private func computeHeight(_ entry: DiffTableRow) -> CGFloat {
        if rich[entry] != nil {
            return Metrics.fittingHeight(DiffRowContent(store: store, row: entry), width: width)
        }
        switch entry {
        case .fileHeader: return metrics.fileHeader
        case .fileTop: return metrics.emptyFileTop
        case .row(let fileID, let index):
            let file = files[fileID]
            guard case .line(let lineIndex) = file.rows[index].kind else { return metrics.hunkHeader }
            let line = file.lines[lineIndex]
            let available = width - gutterTotalWidth(file.gutterDigits) - markerWidth
                - (line.noNewlineAtEnd ? 16 : 0)
            let text = codeText(line.text)
            // Most lines are ASCII and fit: in a monospaced font that needs no layout.
            if metrics.isMonospaced, let columns = CodeColumns.width(of: text),
               CGFloat(columns) * metrics.advance + 2 < available {
                return metrics.line
            }
            let textHeight = CodeLineNSView.height(of: text, font: metrics.font,
                                                   noNewlineAtEnd: line.noNewlineAtEnd,
                                                   width: width - gutterTotalWidth(file.gutterDigits) - markerWidth)
            return metrics.line - metrics.textLine + textHeight
        }
    }

    /// A cell laid out its content at a height other than its row's (a composer growing as
    /// text is typed, or anything measured slightly off): give the row that height.
    private func cellReported(_ height: CGFloat, for entry: DiffTableRow) {
        guard height > 0, let row = layout.index(of: entry),
              abs((heights[entry] ?? 0) - height) > 0.5 else { return }
        heights[entry] = height
        noteHeightChanged(IndexSet(integer: row))
    }

    /// Batched and deferred: cells report from inside layout, where the table can't change.
    private func noteHeightChanged(_ rows: IndexSet) {
        let wasEmpty = heightNotesPending.isEmpty
        heightNotesPending.formUnion(rows)
        guard wasEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rows = self.heightNotesPending.filteredIndexSet { $0 < self.tableView.numberOfRows }
                self.heightNotesPending = []
                guard !rows.isEmpty else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    self.tableView.noteHeightOfRows(withIndexesChanged: rows)
                }
            }
        }
    }

    private func resized() {
        guard width > 0, width != heightsWidth else { return }
        // While the window is dragged, rows keep their width (see DiffCellView) and so their
        // heights; they're measured again once, when the drag ends.
        if ready, tableView.inLiveResize { return }
        heightsWidth = width
        heights = [:]
        if !ready {
            ready = true
            tableView.reloadData()
            tableView.sizeLastColumnToFit()
            if let request = store.scrollRequest { jump(to: request.fileID, line: request.lineIndex) }
            return
        }
        // Lines above re-wrap, so keep the row at the top in place rather than the offset.
        // A reload, because noting every row's height changed makes the table estimate the
        // rows it hasn't asked about again, and its offsets drift from the real heights.
        let anchor = topAnchor()
        tableView.reloadData()
        restore(anchor)
        // Resizes arrive mid-layout, and the table only picks the pinned header for the new
        // offset once that layout is done; scrolling again afterwards refreshes it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.restore(anchor) }
        }
    }

    // MARK: Following the store

    /// What a rich row shows, to tell when it needs measuring again.
    private struct RichContent: Equatable {
        var comments: [ReviewComment] = []
        var composer = false
        var editing: UUID?
        var notice = false
    }

    private func richContent() -> [DiffTableRow: RichContent] {
        var result: [DiffTableRow: RichContent] = [:]
        let editing = store.editingID
        for file in files {
            let comments = store.fileComments[file.path] ?? []
            let expanded = !store.collapsed.contains(file.id)
            let content = RichContent(
                comments: comments, composer: store.fileComposerID == file.id,
                editing: comments.contains { $0.id == editing } ? editing : nil,
                notice: expanded && (file.diff.isBinary || file.rows.isEmpty))
            if content != RichContent() { result[.fileTop(file: file.id)] = content }

            for (anchor, comments) in store.lineComments[file.path] ?? [:] {
                guard let line = file.lineOfAnchor[anchor] else { continue }
                result[.row(file: file.id, index: file.rowOfLine[line]), default: RichContent()].comments = comments
                if comments.contains(where: { $0.id == editing }) {
                    result[.row(file: file.id, index: file.rowOfLine[line])]?.editing = editing
                }
            }
            if let line = store.composerLine(fileID: file.id), file.rowOfLine.indices.contains(line) {
                result[.row(file: file.id, index: file.rowOfLine[line]), default: RichContent()].composer = true
            }
        }
        return result
    }

    private func observeContent() {
        withObservationTracking {
            _ = store.collapsed
            _ = store.showingFullFile
            _ = store.lineComments
            _ = store.fileComments
            _ = store.selection
            _ = store.isDraggingSelection
            _ = store.fileComposerID
            _ = store.editingID
            _ = CodeFontSettings.shared.nsFont
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.contentChanged()
                    self?.observeContent()
                }
            }
        }
    }

    private func contentChanged() {
        if store.showingFullFile != showingFullFile {
            switchedViews()
            return
        }
        let newRich = richContent()
        let changed = Set(rich.keys).union(newRich.keys).filter { rich[$0] != newRich[$0] }
        rich = newRich

        let fontChanged = CodeFontSettings.shared.nsFont != metrics.font
        if fontChanged {
            metrics = Metrics.measure(store)
            heights = [:]
        } else {
            for entry in changed { heights[entry] = nil }
        }

        if store.collapsed != collapsed || fontChanged {
            collapsed = store.collapsed
            reloadKeepingPosition()
        } else if !changed.isEmpty {
            noteHeightChanged(IndexSet(changed.compactMap { layout.index(of: $0) }))
        }
    }

    /// Files switched between their diff and their whole version: every row of theirs is a
    /// different row now. The line at the top stays at the top when the other view has it.
    private func switchedViews() {
        let anchor = topAnchor()
        // The line at the top, by its anchor, which names the same line in both views.
        let topLine: LineAnchor? = anchor.flatMap { anchor in
            guard case .row(let file, let index) = anchor.entry,
                  case .line(let line) = files[file].rows[index].kind else { return nil }
            return files[file].lines[line].anchor
        }

        showingFullFile = store.showingFullFile
        files = store.files.map { store.shown($0.id) }
        collapsed = store.collapsed
        rich = richContent()
        heights = [:]
        lineSpaceWidth = -1
        layout = DiffTableLayout(rowCounts: files.map(\.rows.count), collapsed: collapsed)
        guard ready else { return }
        tableView.reloadData()

        guard var anchor else { return }
        if let topLine, let line = files[anchor.entry.file].lineOfAnchor[topLine] {
            anchor.entry = .row(file: anchor.entry.file, index: files[anchor.entry.file].rowOfLine[line])
        } else if case .row = anchor.entry {
            // The line isn't in this view: start at the file's header.
            anchor = (.fileHeader(file: anchor.entry.file), 0)
        }
        restore(anchor)
    }

    /// Rebuilds the rows after files fold or unfold or the font changes, keeping the row at the
    /// top in place (or, if it folded away, its file's header).
    private func reloadKeepingPosition() {
        let anchor = topAnchor()
        layout = DiffTableLayout(rowCounts: files.map(\.rows.count), collapsed: collapsed)
        guard ready else { return }
        tableView.reloadData()
        restore(anchor)
    }

    private typealias Anchor = (entry: DiffTableRow, offset: CGFloat)

    /// The row at the top of the viewport, and how far it's scrolled past.
    private func topAnchor() -> Anchor? {
        let y = scrollView.contentView.bounds.minY
        let row = tableView.row(at: NSPoint(x: 1, y: y))
        guard row >= 0 else { return nil }
        return (layout.rows[row], y - tableView.rect(ofRow: row).minY)
    }

    /// Scrolls the anchor's row back to the top, or its file's header if the row is gone.
    private func restore(_ anchor: Anchor?) {
        guard let anchor else { return }
        if let row = layout.index(of: anchor.entry) {
            scroll(to: tableView.rect(ofRow: row).minY + anchor.offset)
        } else if let row = layout.headerRow(ofFile: anchor.entry.file) {
            scroll(to: tableView.rect(ofRow: row).minY)
        }
    }

    // MARK: Scrolling

    private func observeScrollRequests() {
        withObservationTracking {
            _ = store.scrollRequest
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let request = self.store.scrollRequest { self.jump(to: request.fileID, line: request.lineIndex) }
                    self.observeScrollRequests()
                }
            }
        }
    }

    /// Scrolls to a file's header, or with `line`, to that line, a few lines below the
    /// pinned header so it isn't hidden under it.
    private func jump(to fileID: Int, line: Int? = nil) {
        if let line, ready, files[fileID].rowOfLine.indices.contains(line),
           let row = layout.index(of: .row(file: fileID, index: files[fileID].rowOfLine[line])) {
            scroll(to: tableView.rect(ofRow: row).minY - metrics.fileHeader - 3 * metrics.line)
            return
        }
        guard ready, let row = layout.headerRow(ofFile: fileID) else { return }
        jumping = true
        scroll(to: tableView.rect(ofRow: row).minY)
        jumping = false
        // The table picks the pinned header for the new offset only after its next layout;
        // until then the previous file's header covers this one's. Scrolling again refreshes it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, row < self.tableView.numberOfRows else { return }
                self.jumping = true
                self.scroll(to: self.tableView.rect(ofRow: row).minY)
                self.jumping = false
            }
        }
    }

    private func scroll(to y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, tableView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Highlights, in the sidebar, the file being read: the first with code on screen under
    /// the pinned header, not a collapsed file whose header happens to sit there.
    private func scrolled() {
        guard ready, !jumping else { return }
        let bounds = scrollView.contentView.bounds
        let top = tableView.row(at: NSPoint(x: 1, y: bounds.minY + metrics.fileHeader))
        guard top >= 0 else { return }
        let bottom = tableView.row(at: NSPoint(x: 1, y: bounds.maxY - 1))
        let end = bottom >= 0 ? bottom + 1 : layout.rows.count
        guard let file = layout.fileBeingRead(inRows: top..<end) else { return }
        store.diffScrolled(toFile: file)
    }
}

/// Heights of the rows whose height only depends on the font.
@MainActor
private struct Metrics {
    let font: NSFont
    let isMonospaced: Bool
    /// Width of one character cell.
    let advance: CGFloat
    /// One line of code as TextKit lays it out.
    let textLine: CGFloat
    /// A diff line that doesn't wrap.
    let line: CGFloat
    let hunkHeader: CGFloat
    let fileHeader: CGFloat
    /// A file's top row with no comments, composer or notice.
    let emptyFileTop: CGFloat = 1

    /// - Parameter store: has at least one file (an empty diff never opens).
    static func measure(_ store: ReviewStore) -> Metrics {
        let font = CodeFontSettings.shared.nsFont
        let sample = DiffLine(kind: .context, text: "x", oldNumber: 1, newNumber: 1)
        let line = fittingHeight(
            LineRow(line: sample, digits: 3, selected: false, onClick: { _ in }) {
                CodeLineView(code: "x", font: font, fileID: -1, lineIndex: 0,
                             highlight: nil, noNewlineAtEnd: false,
                             onClick: { _ in }, onDragBegin: { _ in }, onDragMove: { _, _ in }, onDragEnd: {})
            }, width: 800)
        return Metrics(
            font: font,
            isMonospaced: font.isFixedPitch,
            advance: (" " as NSString).size(withAttributes: [.font: font]).width,
            textLine: NSLayoutManager().defaultLineHeight(for: font),
            line: line,
            hunkHeader: fittingHeight(HunkHeaderRow(header: "@@ -1,1 +1,1 @@", digits: 3), width: 800),
            fileHeader: fittingHeight(FileHeader(store: store, file: store.files[0]), width: 800))
    }

    static func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        // Measured as cells lay rows out: at their natural height, not filling the proposal.
        let controller = NSHostingController(rootView: view.frame(width: max(1, width))
            .fixedSize(horizontal: false, vertical: true))
        controller.sizingOptions = []
        return controller.sizeThatFits(in: CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height
    }
}
