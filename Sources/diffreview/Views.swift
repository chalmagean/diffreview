import AppKit
import DiffReviewCore
import SwiftUI

enum Palette {
    static let addBG = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.18, green: 0.32, blue: 0.20, alpha: 0.55) : NSColor(red: 0.90, green: 0.98, blue: 0.91, alpha: 1) })
    static let delBG = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.40, green: 0.17, blue: 0.18, alpha: 0.55) : NSColor(red: 1.0, green: 0.92, blue: 0.92, alpha: 1) })
    static let addGutter = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.18, green: 0.40, blue: 0.22, alpha: 0.6) : NSColor(red: 0.80, green: 0.95, blue: 0.82, alpha: 1) })
    static let delGutter = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.50, green: 0.20, blue: 0.21, alpha: 0.6) : NSColor(red: 1.0, green: 0.84, blue: 0.85, alpha: 1) })
    static let hunkBG = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(red: 0.16, green: 0.22, blue: 0.33, alpha: 0.7) : NSColor(red: 0.87, green: 0.93, blue: 1.0, alpha: 1) })
    static let selected = Color.yellow.opacity(0.28)
    static let added = Color(nsColor: .systemGreen)
    static let deleted = Color(nsColor: .systemRed)
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

let codeFont = Font.system(size: 12, design: .monospaced)

// MARK: - Root

struct RootView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        HSplitView {
            FileListView(store: store)
                .frame(minWidth: 200, idealWidth: 270, maxWidth: 340)
            VStack(spacing: 0) {
                TopBar(store: store)
                Divider()
                DiffView(store: store)
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: 700, minHeight: 400)
    }
}

struct TopBar: View {
    @Bindable var store: ReviewStore
    @State private var showFinish = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.title).font(.headline)
                HStack(spacing: 6) {
                    Text(verbatim: "\(store.files.count) file\(store.files.count == 1 ? "" : "s")")
                    Text(verbatim: "+\(store.totalAdditions)").foregroundStyle(Palette.added)
                    Text(verbatim: "−\(store.totalDeletions)").foregroundStyle(Palette.deleted)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Expand all") { store.setAllCollapsed(false) }
            Button("Collapse all") { store.setAllCollapsed(true) }
            Button {
                showFinish = true
            } label: {
                Text(store.draft.comments.isEmpty ? "Finish review" : "Finish review (\(store.draft.comments.count))")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .popover(isPresented: $showFinish, arrowEdge: .bottom) {
                FinishReviewView(store: store, isPresented: $showFinish)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct FinishReviewView: View {
    @Bindable var store: ReviewStore
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish your review").font(.headline)
            TextEditor(text: $store.draft.summary)
                .font(.body)
                .focused($focused)
                .frame(width: 420, height: 140)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if store.draft.summary.isEmpty {
                        Text("Overall summary (optional)").foregroundStyle(.tertiary).padding(9).allowsHitTesting(false)
                    }
                }
            let count = store.draft.comments.count
            Text(count == 0 ? "No inline or file comments." : "\(count) comment\(count == 1 ? "" : "s") will be included.")
                .font(.caption).foregroundStyle(.secondary)
            let stale = store.staleComments.count
            if stale > 0 {
                HStack {
                    Text("\(stale) restored comment\(stale == 1 ? " is" : "s are") on files no longer in this diff.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Discard them") { store.discardStaleComments() }.controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Submit review") { store.submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

// MARK: - Sidebar

struct FileListView: View {
    @Bindable var store: ReviewStore
    @State private var selected: Int?

    var body: some View {
        List(selection: $selected) {
            ForEach(store.files) { file in
                FileListRow(file: file, comments: store.commentCounts[file.path] ?? 0)
                    .tag(file.id)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selected) { _, id in
            if let id { store.reveal(fileID: id) }
        }
    }
}

struct FileListRow: View {
    let file: DisplayFile
    let comments: Int

    var body: some View {
        let path = file.path as NSString
        HStack(spacing: 6) {
            StatusBadge(file: file.diff)
            VStack(alignment: .leading, spacing: 1) {
                Text(path.lastPathComponent).lineLimit(1).truncationMode(.middle)
                let dir = path.deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if comments > 0 {
                Label(String(comments), systemImage: "text.bubble")
                    .labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.blue)
            }
            DiffCounts(additions: file.diff.additions, deletions: file.diff.deletions)
        }
        .help(file.diff.displayPath)
    }
}

struct StatusBadge: View {
    let file: FileDiff

    var body: some View {
        let letter = file.isUntracked ? "U" : file.status.letter
        let color: Color = {
            if file.isUntracked { return .green }
            switch file.status {
            case .added: return .green
            case .deleted: return .red
            case .renamed, .copied: return .purple
            case .modified: return .orange
            }
        }()
        Text(letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.85)))
            .help(file.isUntracked ? "Untracked" : file.status.rawValue.capitalized)
    }
}

struct DiffCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(additions)").foregroundStyle(Palette.added)
            Text(verbatim: "−\(deletions)").foregroundStyle(Palette.deleted)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

// MARK: - Diff

/// LazyVStack keeps launch fast on huge diffs (List eagerly walks every row identity).
/// Scroll targets are each file's always-present first row, not the pinned header.
struct DiffView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.files) { file in
                        Section {
                            FileBody(store: store, file: file)
                        } header: {
                            FileHeader(store: store, file: file)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .onChange(of: store.scrollRequest) { _, request in
                guard let request else { return }
                // LazyVStack only estimates the height of rows it hasn't built, so a long jump
                // lands short. Re-issuing the scroll as rows materialise converges on the target.
                let id = FileBody.scrollID(request.fileID)
                proxy.scrollTo(id, anchor: .top)
                for delay in [0.05, 0.15, 0.3, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard store.scrollRequest == request else { return }
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct FileHeader: View {
    @Bindable var store: ReviewStore
    let file: DisplayFile

    var body: some View {
        let isCollapsed = store.collapsed.contains(file.id)
        HStack(spacing: 8) {
            Button {
                store.toggleCollapsed(file.id)
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            StatusBadge(file: file.diff)
            Text(file.diff.displayPath)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            if file.diff.isUntracked { Tag(text: "untracked") }
            if file.diff.isBinary { Tag(text: "binary") }
            if let o = file.diff.oldMode, let n = file.diff.newMode, o != n { Tag(text: "\(o) → \(n)") }
            DiffCounts(additions: file.diff.additions, deletions: file.diff.deletions)
            Spacer()
            Button {
                store.openFileComposer(fileID: file.id)
            } label: {
                Label("Comment on file", systemImage: "text.bubble")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { store.toggleCollapsed(file.id) }
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().stroke(Color.secondary.opacity(0.5)))
            .foregroundStyle(.secondary)
    }
}

/// Everything below a file's header. Each top-level view is one List row.
struct FileBody: View {
    @Bindable var store: ReviewStore
    let file: DisplayFile

    static func scrollID(_ fileID: Int) -> String { "file-top-\(fileID)" }

    var body: some View {
        // Always present (even when collapsed) so it can serve as the scroll target.
        FileTopRow(store: store, file: file)

            .id(Self.scrollID(file.id))

        if !store.collapsed.contains(file.id) {
            ForEach(file.rows) { row in
                switch row.kind {
                case .hunkHeader(let header):
                    HunkHeaderRow(header: header, digits: file.gutterDigits)
            
                case .line(let index):
                    LineBlock(store: store, file: file, index: index)
            
                }
            }
        }
    }
}

/// File-level comments, the file composer, and "binary / empty" notices.
struct FileTopRow: View {
    @Bindable var store: ReviewStore
    let file: DisplayFile

    var body: some View {
        let fileLevel = store.fileComments[file.path] ?? []
        let expanded = !store.collapsed.contains(file.id)
        VStack(alignment: .leading, spacing: 0) {
            if !fileLevel.isEmpty || store.fileComposerID == file.id {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(fileLevel) { comment in
                        CommentView(store: store, comment: comment, outdated: store.isOutdated(comment))
                    }
                    if store.fileComposerID == file.id {
                        ComposerView(text: $store.fileComposerText, title: "Comment on \(file.path)",
                                     onCancel: store.cancelFileComposer, onSubmit: store.addFileComment)
                    }
                }
                .padding(.vertical, 4)
            }
            if expanded && file.diff.isBinary {
                Notice(text: "Binary file not shown")
            } else if expanded && file.rows.isEmpty {
                Notice(text: file.diff.status == .renamed ? "File renamed without changes"
                       : file.diff.status == .added ? "Empty file" : "No content changes")
            }
            Color.clear.frame(height: 1)
        }
    }
}

struct Notice: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func gutterWidth(_ digits: Int) -> CGFloat { CGFloat(digits) * 7.3 + 14 }

struct HunkHeaderRow: View {
    let header: String
    let digits: Int

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth(digits) * 2 + 16)
            Text(header)
                .font(codeFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .background(Palette.hunkBG)
    }
}

/// A diff line plus any comments anchored under it and the composer if it's open there.
struct LineBlock: View {
    @Bindable var store: ReviewStore
    let file: DisplayFile
    let index: Int

    var body: some View {
        let line = file.lines[index]
        let comments = line.anchor.flatMap { store.lineComments[file.path]?[$0] } ?? []
        let showComposer = store.composerLine(fileID: file.id) == index
        VStack(alignment: .leading, spacing: 0) {
        LineRow(line: line, digits: file.gutterDigits,
                code: store.highlighter.highlight(displayText(line.text), language: file.language),
                selected: store.isSelected(fileID: file.id, lineIndex: index))
            .onTapGesture {
                store.click(fileID: file.id, lineIndex: index, extend: NSEvent.modifierFlags.contains(.shift))
            }
        if !comments.isEmpty || showComposer {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(comments) { comment in
                    CommentView(store: store, comment: comment, outdated: false)
                }
                if showComposer, let sel = store.selection {
                    ComposerView(text: $store.composerText,
                                 title: composerTitle(sel),
                                 onCancel: store.cancelComposer, onSubmit: store.addLineComment)
                }
            }
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        }
        }
    }

    func composerTitle(_ sel: LineSelection) -> String {
        let preview = ReviewComment.line(path: file.path, lines: Array(file.lines[sel.range]), body: "")
        return "Comment on \(preview.rangeLabel.lowercased()) · shift-click to extend"
    }
}

func displayText(_ text: String) -> String {
    var t = text
    if t.hasSuffix("\r") { t.removeLast() }
    return t.replacingOccurrences(of: "\t", with: "    ")
}

struct LineRow: View {
    let line: DiffLine
    let digits: Int
    let code: AttributedString
    let selected: Bool

    var body: some View {
        let (marker, bg, gutterBG): (String, Color, Color) = {
            switch line.kind {
            case .addition: return ("+", Palette.addBG, Palette.addGutter)
            case .deletion: return ("-", Palette.delBG, Palette.delGutter)
            case .context: return (" ", .clear, .clear)
            }
        }()
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: gutterWidth(digits), alignment: .trailing)
                .padding(.trailing, 4)
                .foregroundStyle(.secondary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: gutterWidth(digits), alignment: .trailing)
                .padding(.trailing, 4)
                .foregroundStyle(.secondary)
                .background(gutterBG)
            Text(marker)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(code)
                    .fixedSize(horizontal: false, vertical: true)
                if line.noNewlineAtEnd {
                    Image(systemName: "nosign")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .help("No newline at end of file")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(codeFont)
        .padding(.vertical, 1)
        .background(selected ? Palette.selected : bg)
        .contentShape(Rectangle())
    }
}

// MARK: - Comments

struct ComposerView: View {
    @Binding var text: String
    let title: String
    var submitLabel = "Add comment"
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                // Handled on the editor itself: button keyboard shortcuts inside a lazy
                // stack don't fire reliably.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    onSubmit()
                    return .handled
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .frame(minHeight: 64, maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.6)))
            HStack {
                Text("⌘↩ to \(submitLabel.lowercased()) · esc to cancel").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button(submitLabel, action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: 860, alignment: .leading)
        .onAppear { focused = true }
    }
}

struct CommentView: View {
    @Bindable var store: ReviewStore
    let comment: ReviewComment
    let outdated: Bool

    var body: some View {
        if store.editingID == comment.id {
            ComposerView(text: $store.editText, title: "Edit comment · \(label)",
                         submitLabel: "Save",
                         onCancel: store.cancelEdit,
                         onSubmit: store.commitEdit)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(.blue)
                    Text(label).font(.caption.weight(.semibold))
                    if outdated { Tag(text: "outdated") }
                    Spacer()
                    Button("Edit") { store.beginEdit(comment) }
                    .buttonStyle(.link)
                    Button("Delete", role: .destructive) { store.delete(comment.id) }
                        .buttonStyle(.link)
                        .foregroundStyle(.red)
                }
                .font(.caption)
                Text(comment.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    var label: String {
        comment.isFileLevel ? "File comment" : comment.rangeLabel
    }
}
