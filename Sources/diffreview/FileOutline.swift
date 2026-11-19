import AppKit
import DiffReviewCore
import SwiftUI

/// The sidebar's folder tree, drawn by an AppKit outline view. A SwiftUI List diffs every row
/// whenever its selection moves, and the selection follows the diff as it scrolls: with
/// thousands of files that made scrolling crawl. Moving the selection here is one row.
struct FileOutline: NSViewRepresentable {
    let store: ReviewStore
    /// The sidebar filter, already trimmed. While filtering, every folder is open.
    let query: String

    func makeCoordinator() -> FileOutlineController { FileOutlineController(store: store) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.show(query: query)
    }
}

/// A row of the tree. A class, because the outline view tells items apart by identity.
final class FileOutlineItem {
    let name: String
    let path: String
    let fileID: Int?
    let children: [FileOutlineItem]

    init(_ node: FileTreeNode, files: [DisplayFile]) {
        name = node.name
        path = node.path
        switch node {
        case .directory(_, _, let nodes):
            fileID = nil
            children = nodes.map { FileOutlineItem($0, files: files) }
        case .file(_, _, let index):
            fileID = files[index].id
            children = []
        }
    }
}

/// What a row shows; `emphasized` when it's selected in the focused outline (white text).
private struct FileOutlineRow: View {
    let store: ReviewStore
    let item: FileOutlineItem
    let emphasized: Bool

    var body: some View {
        Group {
            if let id = item.fileID {
                let file = store.files[id]
                HStack(spacing: 6) {
                    StatusBadge(file: file.diff)
                    Text((file.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    let comments = store.commentCounts[file.path] ?? 0
                    if comments > 0 {
                        Label(String(comments), systemImage: "text.bubble")
                            .labelStyle(.titleAndIcon).font(.caption2)
                            .foregroundStyle(emphasized ? Color.white : Color.blue)
                    }
                    DiffCounts(additions: file.diff.additions, deletions: file.diff.deletions)
                }
                .help(file.diff.displayPath)
            } else {
                Label {
                    Text(item.name).lineLimit(1).truncationMode(.head)
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(emphasized ? Color.white : Color.blue)
                }
                .help(item.path)
            }
        }
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private final class FileOutlineCell: NSTableCellView {
    let hosting: NSHostingView<FileOutlineRow>
    private var store: ReviewStore
    var item: FileOutlineItem { didSet { refresh() } }

    init(store: ReviewStore, item: FileOutlineItem) {
        self.store = store
        self.item = item
        hosting = NSHostingView(rootView: FileOutlineRow(store: store, item: item, emphasized: false))
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { refresh() } }
    }

    func refresh() {
        hosting.rootView = FileOutlineRow(store: store, item: item, emphasized: backgroundStyle == .emphasized)
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
}

@MainActor
final class FileOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let store: ReviewStore
    let scrollView = NSScrollView()
    private let outline = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "No matching files")

    private var roots: [FileOutlineItem] = []
    private var itemOfFile: [Int: FileOutlineItem] = [:]
    private var query: String?
    /// Folders the user folded, by path; they stay folded when the filter changes.
    private var foldedFolders: Set<String> = []
    /// Set while the outline is changed from code, so its callbacks aren't taken as the user's.
    private var updating = false

    init(store: ReviewStore) {
        self.store = store
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 28
        outline.indentationPerLevel = 12
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .preferredFont(forTextStyle: .callout)
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        observeStore()
    }

    /// Rebuilds the tree for a new filter.
    func show(query: String) {
        guard query != self.query else { return }
        self.query = query
        let shown = query.isEmpty ? store.files
            : store.files.filter { $0.path.localizedCaseInsensitiveContains(query) }
        roots = FileTree.build(paths: shown.map(\.path)).map { FileOutlineItem($0, files: shown) }
        itemOfFile = [:]
        func index(_ items: [FileOutlineItem]) {
            for item in items {
                if let id = item.fileID { itemOfFile[id] = item }
                index(item.children)
            }
        }
        index(roots)
        emptyLabel.isHidden = !shown.isEmpty

        updating = true
        outline.reloadData()
        func expand(_ items: [FileOutlineItem]) {
            for item in items where item.fileID == nil {
                if query.isEmpty && foldedFolders.contains(item.path) { continue }
                outline.expandItem(item)
                expand(item.children)
            }
        }
        expand(roots)
        updating = false
        followVisibleFile()
    }

    // MARK: Data source & delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileOutlineItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileOutlineItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileOutlineItem)?.fileID == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FileOutlineItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileOutlineCell {
            cell.item = item
            return cell
        }
        let cell = FileOutlineCell(store: store, item: item)
        cell.identifier = identifier
        return cell
    }

    /// Folders fold rather than select.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? FileOutlineItem)?.fileID != nil
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !updating, query?.isEmpty == true,
              let item = notification.userInfo?["NSObject"] as? FileOutlineItem else { return }
        foldedFolders.insert(item.path)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !updating, query?.isEmpty == true,
              let item = notification.userInfo?["NSObject"] as? FileOutlineItem else { return }
        foldedFolders.remove(item.path)
    }

    /// Arrow keys move the selection: show that file. (Clicks are handled in `clicked`.)
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating, NSApp.currentEvent?.type == .keyDown,
              let id = (outline.item(atRow: outline.selectedRow) as? FileOutlineItem)?.fileID,
              id != store.visibleFileID else { return }
        store.reveal(fileID: id)
    }

    /// A click on a file shows it, even the highlighted one (back to its top); on a folder,
    /// folds or unfolds it.
    @objc private func clicked(_ sender: Any?) {
        guard let item = outline.item(atRow: outline.clickedRow) as? FileOutlineItem else { return }
        if let id = item.fileID {
            store.reveal(fileID: id)
        } else if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        } else {
            outline.expandItem(item)
        }
    }

    // MARK: Following the store

    private func observeStore() {
        withObservationTracking {
            _ = store.visibleFileID
            _ = store.commentCounts
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.followVisibleFile()
                    self.refreshVisibleRows()
                    self.observeStore()
                }
            }
        }
    }

    /// Highlights the file the diff shows, scrolling the sidebar to keep it in view.
    private func followVisibleFile() {
        let row = store.visibleFileID.flatMap { itemOfFile[$0] }.map { outline.row(forItem: $0) } ?? -1
        guard row != outline.selectedRow else { return }
        updating = true
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        updating = false
    }

    /// Comment counts changed: redraw the rows on screen (others are built fresh when shown).
    private func refreshVisibleRows() {
        let rows = outline.rows(in: outline.visibleRect)
        for row in rows.location..<NSMaxRange(rows) {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileOutlineCell)?.refresh()
        }
    }
}
