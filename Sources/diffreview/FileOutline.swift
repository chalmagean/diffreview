import AppKit
import DiffReviewCore
import SwiftUI

/// The sidebar's folder tree, drawn by an AppKit table of rows we flatten ourselves. A SwiftUI
/// List diffs every row whenever its selection moves, and the selection follows the diff as
/// it scrolls: with thousands of files that made scrolling crawl. An NSOutlineView fixed that
/// but opens folders one at a time, retiling every row below each one, so filtering 6k files
/// took seconds per keystroke. Here a new filter is one pass over the tree and a reload.
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

/// A row of the tree as the sidebar shows it.
struct FileOutlineItem {
    let name: String
    let path: String
    /// The file's id in the store; nil for a folder.
    let fileID: Int?
    let depth: Int
    /// For a folder: whether its entries are listed under it.
    let isOpen: Bool
}

/// What a row shows; `emphasized` when it's selected in the focused table (white text).
private struct FileOutlineRow: View {
    let store: ReviewStore
    let item: FileOutlineItem
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(emphasized ? Color.white : Color.secondary)
                .rotationEffect(.degrees(item.isOpen ? 90 : 0))
                .frame(width: 12)
                .opacity(item.fileID == nil ? 1 : 0)
            content
        }
        .padding(.leading, CGFloat(item.depth) * 12)
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if let id = item.fileID {
            let file = store.files[id]
            HStack(spacing: 6) {
                StatusBadge(file: file.diff)
                Text(item.name).lineLimit(1).truncationMode(.middle)
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
final class FileOutlineController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let store: ReviewStore
    let scrollView = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching files")

    /// The files the filter lets through, and their tree.
    private var shown: [DisplayFile] = []
    private var tree: [FileTreeNode] = []
    private var items: [FileOutlineItem] = []
    private var rowOfFile: [Int: Int] = [:]
    private var query: String?
    /// Folders the user folded, by path; they stay folded when the filter changes.
    private var foldedFolders: Set<String> = []
    /// Folders folded while filtering; every folder opens again when the filter changes.
    private var foldedWhileFiltering: Set<String> = []
    /// Set while the table is changed from code, so its callbacks aren't taken as the user's.
    private var updating = false

    init(store: ReviewStore) {
        self.store = store
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 28
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))

        scrollView.documentView = table
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
        foldedWhileFiltering = []
        shown = query.isEmpty ? store.files
            : store.files.filter { $0.path.localizedCaseInsensitiveContains(query) }
        tree = FileTree.build(paths: shown.map(\.path))
        emptyLabel.isHidden = !shown.isEmpty
        reloadRows()
    }

    /// Lists the tree's rows again, after a filter or a fold.
    private func reloadRows() {
        let folded = query?.isEmpty != false ? foldedFolders : foldedWhileFiltering
        rowOfFile = [:]
        items = FileTree.rows(tree, folded: folded).enumerated().map { row, entry in
            switch entry.node {
            case .directory(let name, let path, _):
                return FileOutlineItem(name: name, path: path, fileID: nil, depth: entry.depth,
                                       isOpen: !folded.contains(path))
            case .file(let name, let path, let index):
                let id = shown[index].id
                rowOfFile[id] = row
                return FileOutlineItem(name: name, path: path, fileID: id, depth: entry.depth, isOpen: false)
            }
        }
        updating = true
        table.reloadData()
        updating = false
        followVisibleFile()
    }

    private func toggle(folder path: String) {
        if query?.isEmpty != false {
            if foldedFolders.remove(path) == nil { foldedFolders.insert(path) }
        } else {
            if foldedWhileFiltering.remove(path) == nil { foldedWhileFiltering.insert(path) }
        }
        reloadRows()
    }

    // MARK: Data source & delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let identifier = NSUserInterfaceItemIdentifier("row")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileOutlineCell {
            cell.item = item
            return cell
        }
        let cell = FileOutlineCell(store: store, item: item)
        cell.identifier = identifier
        return cell
    }

    /// Folders fold rather than select.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        items[row].fileID != nil
    }

    /// Arrow keys move the selection: show that file. (Clicks are handled in `clicked`.)
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, NSApp.currentEvent?.type == .keyDown,
              table.selectedRow >= 0, let id = items[table.selectedRow].fileID,
              id != store.visibleFileID else { return }
        store.reveal(fileID: id)
    }

    /// A click on a file shows it, even the highlighted one (back to its top); on a folder,
    /// folds or unfolds it.
    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0 else { return }
        if let id = items[row].fileID {
            store.reveal(fileID: id)
        } else {
            toggle(folder: items[row].path)
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
        let row = store.visibleFileID.flatMap { rowOfFile[$0] } ?? -1
        guard row != table.selectedRow else { return }
        updating = true
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        updating = false
    }

    /// Comment counts changed: redraw the rows on screen (others are built fresh when shown).
    private func refreshVisibleRows() {
        let rows = table.rows(in: table.visibleRect)
        for row in rows.location..<NSMaxRange(rows) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileOutlineCell)?.refresh()
        }
    }
}
