import AppKit
import DiffReviewCore
import SwiftUI

/// GitHub's diff colours (Primer): each kind of row has a code colour and a stronger
/// line-number colour.
enum Palette {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let addBG = dynamic(light: rgb(0xE6FFEC), dark: rgb(0x2EA043, 0.15))
    static let addGutter = dynamic(light: rgb(0xCCFFD8), dark: rgb(0x3FB950, 0.3))
    static let delBG = dynamic(light: rgb(0xFFEBE9), dark: rgb(0xF85149, 0.1))
    static let delGutter = dynamic(light: rgb(0xFFD7D5), dark: rgb(0xF85149, 0.3))
    static let hunkBG = dynamic(light: rgb(0xDDF4FF), dark: rgb(0x388BFD, 0.1))
    static let hunkGutter = dynamic(light: rgb(0xB6E3FF), dark: rgb(0x388BFD, 0.3))
    static let selectedBG = dynamic(light: rgb(0xFFF8C5), dark: rgb(0xBB8009, 0.15))
    static let selectedGutter = dynamic(light: rgb(0xF8E3A1), dark: rgb(0xBB8009, 0.4))
    static let commentButton = dynamic(light: rgb(0x0969DA), dark: rgb(0x1F6FEB))
    static let addWord = NSColor(name: nil) { $0.isDark ? rgb(0x2EA043, 0.4) : rgb(0xABF2BC) }
    static let delWord = NSColor(name: nil) { $0.isDark ? rgb(0xF85149, 0.4) : rgb(0xFFCECB) }
    static let added = Color(nsColor: .systemGreen)
    static let deleted = Color(nsColor: .systemRed)
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// The code font chosen in Settings. Reading it from a view body makes that view follow changes.
@MainActor var codeFont: Font { CodeFontSettings.shared.font }

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
            if store.chats.isOpen && store.chats.isAvailable {
                ChatSidebar(chats: store.chats, onReveal: { store.reveal($0) },
                            onAskAboutReview: { store.askAboutReview($0) })
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: 700)
            }
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
            if store.chats.isAvailable {
                let count = store.chats.chats.count
                Button {
                    store.chats.isOpen.toggle()
                } label: {
                    Label(count == 0 ? "Chats" : "Chats (\(count))", systemImage: "bubble.left.and.bubble.right")
                }
                .help(store.chats.isOpen ? "Hide the chats (⌥⌘C)" : "Show the chats, to ask Claude about the diff (⌥⌘C)")
                .keyboardShortcut("c", modifiers: [.command, .option])
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish your review").font(.headline)
            PlaceholderTextEditor(text: $store.draft.summary, placeholder: "Overall summary (optional)")
                .frame(width: 420, height: 140)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
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
    }
}

// MARK: - Sidebar

struct FileListView: View {
    @Bindable var store: ReviewStore
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            FilterField(text: $filter)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            FileOutline(store: store, query: filter.trimmingCharacters(in: .whitespaces))
        }
    }
}

struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter files…", text: $text)
                .textFieldStyle(.plain)
                .onKeyPress(.escape) {
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
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

/// The diff, drawn by an AppKit table (see `DiffTable`): it knows every row's height up
/// front, so jumping to a file is one exact scroll however long the diff is.
struct DiffView: View {
    @Bindable var store: ReviewStore

    var body: some View {
        DiffTable(store: store)
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
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            if file.diff.isUntracked { Tag(text: "untracked") }
            if file.diff.isBinary { Tag(text: "binary") }
            if let o = file.diff.oldMode, let n = file.diff.newMode, o != n { Tag(text: "\(o) → \(n)") }
            DiffCounts(additions: file.diff.additions, deletions: file.diff.deletions)
            Spacer()
            ViewModeSwitch(store: store, fileID: file.id)
            Button {
                store.openFileComposer(fileID: file.id)
            } label: {
                Label("Comment on file", systemImage: "text.bubble")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { store.toggleCollapsed(file.id) }
    }
}

/// Diff or whole file, like the view switch in a GitHub file header.
struct ViewModeSwitch: View {
    @Bindable var store: ReviewStore
    let fileID: Int

    var body: some View {
        let enabled = store.canShowFullFile(fileID)
        Picker("View", selection: Binding(
            get: { store.showingFullFile.contains(fileID) },
            set: { store.setShowsFullFile(fileID, $0) })) {
            Image(systemName: "plus.forwardslash.minus")
                .help("Show the diff")
                .tag(false)
            Image(systemName: "doc.text")
                .help(enabled ? "Show the whole file" : "There's no new version of this file to show")
                .tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!enabled)
        .help(enabled ? "Show the diff or the whole file" : "There's no new version of this file to show")
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
                                     onCancel: store.cancelFileComposer, onSubmit: store.addFileComment,
                                     onAsk: askAction)
                    }
                }
                .padding(.vertical, 4)
            }
            if let error = store.fullFileErrors[file.id] {
                Notice(text: "Couldn't show the whole file: \(error)")
            }
            if expanded && file.diff.isBinary {
                Notice(text: "Binary file not shown")
            } else if expanded && file.isFullFile && file.rows.isEmpty {
                Notice(text: "Empty file")
            } else if expanded && file.rows.isEmpty {
                Notice(text: file.diff.status == .renamed ? "File renamed without changes"
                       : file.diff.status == .added ? "Empty file" : "No content changes")
            }
            Color.clear.frame(height: 1)
        }
    }

    private var askAction: (() -> Void)? {
        guard store.chats.isAvailable else { return nil }
        return { [store] in store.askAboutFile() }
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

@MainActor func gutterWidth(_ digits: Int) -> CGFloat { CGFloat(digits) * CodeFontSettings.shared.digitWidth + 14 }
/// Both line-number columns, each with its trailing padding.
@MainActor func gutterTotalWidth(_ digits: Int) -> CGFloat { (gutterWidth(digits) + 4) * 2 }
let markerWidth: CGFloat = 16
let rowPadding: CGFloat = 2

struct HunkHeaderRow: View {
    let header: String
    let digits: Int

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterTotalWidth(digits) + markerWidth)
            Text(header)
                .font(codeFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .background(RowBackground(digits: digits, gutter: Palette.hunkGutter, code: Palette.hunkBG))
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
                    selected: store.isSelected(fileID: file.id, lineIndex: index),
                    inFullFile: file.isFullFile,
                    onClick: { extend in store.click(fileID: file.id, lineIndex: index, extend: extend) }) {
                CodeLineView(
                    code: codeText(line.text),
                    tokens: file.tokens[index],
                    font: CodeFontSettings.shared.nsFont,
                    fileID: file.id, lineIndex: index,
                    highlight: store.highlight(fileID: file.id, lineIndex: index),
                    emphasis: file.emphasis[index] ?? [],
                    emphasisColor: line.kind == .deletion ? Palette.delWord : Palette.addWord,
                    noNewlineAtEnd: line.noNewlineAtEnd,
                    onClick: { extend in store.click(fileID: file.id, lineIndex: index, extend: extend) },
                    onDragBegin: { offset in store.beginTextSelection(fileID: file.id, lineIndex: index, offset: offset) },
                    onDragMove: { line, offset in store.extendTextSelection(fileID: file.id, lineIndex: line, offset: offset) },
                    onDragEnd: store.endTextSelection)
            }
            if !comments.isEmpty || showComposer {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(comments) { comment in
                        CommentView(store: store, comment: comment, outdated: false)
                    }
                    if showComposer, let sel = store.selection {
                        // The selection stays highlighted in the code above, so it isn't quoted here.
                        ComposerView(text: $store.composerText,
                                     title: composerTitle(sel),
                                     onCancel: store.cancelComposer, onSubmit: store.addLineComment,
                                     onAsk: askAction)
                    }
                }
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            }
        }
    }

    private var askAction: (() -> Void)? {
        guard store.chats.isAvailable else { return nil }
        return { [store] in store.askAboutSelection() }
    }

    func composerTitle(_ sel: LineSelection) -> String {
        let preview = ReviewComment.line(path: file.path, lines: Array(file.lines[sel.range]), body: "")
        if sel.isCharacterSelection {
            return "Comment on the selected text · \(preview.rangeLabel.lowercased())"
        }
        return "Comment on \(preview.rangeLabel.lowercased()) · shift-click to extend · drag to select text"
    }
}

struct LineRow<Code: View>: View {
    let line: DiffLine
    let digits: Int
    let selected: Bool
    /// A line of a whole file: what the diff added is marked in the gutter only, so the code
    /// reads as code.
    var inFullFile = false
    let onClick: (_ extend: Bool) -> Void
    @ViewBuilder let code: () -> Code
    @State private var hovering = false

    var body: some View {
        let (marker, bg, gutterBG): (String, Color, Color) = {
            switch line.kind {
            case .addition where inFullFile: return ("+", .clear, Palette.addGutter)
            case .addition: return ("+", Palette.addBG, Palette.addGutter)
            case .deletion: return ("-", Palette.delBG, Palette.delGutter)
            case .context: return (" ", .clear, .clear)
            }
        }()
        HStack(alignment: .top, spacing: 0) {
            // The gutter takes line clicks; the code column handles its own clicks and drags.
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: gutterWidth(digits), alignment: .trailing)
                    .padding(.trailing, 4)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: gutterWidth(digits), alignment: .trailing)
                    .padding(.trailing, 4)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture { onClick(NSEvent.modifierFlags.contains(.shift)) }
            Text(marker)
                .frame(width: markerWidth)
            code()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(codeFont)
        .padding(.vertical, rowPadding)
        .background(RowBackground(digits: digits,
                                  gutter: selected ? Palette.selectedGutter : gutterBG,
                                  code: selected ? Palette.selectedBG : bg))
        .overlay(alignment: .topLeading) {
            if hovering {
                AddCommentButton { onClick(NSEvent.modifierFlags.contains(.shift)) }
                    .offset(x: gutterTotalWidth(digits) - 4, y: rowPadding - 1)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
    }
}

/// A row's two-tone background: the line-number gutter, then the code.
struct RowBackground: View {
    let digits: Int
    let gutter: Color
    let code: Color

    var body: some View {
        HStack(spacing: 0) {
            gutter.frame(width: gutterTotalWidth(digits))
            code
        }
    }
}

/// The blue "+" that appears on a hovered line, as on GitHub.
struct AddCommentButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let side = ceil(CodeFontSettings.shared.lineHeight) + 2
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: side * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: 5).fill(Palette.commentButton))
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .scaleEffect(hovering ? 1.15 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
        .help("Add a comment on this line (shift-click to extend)")
    }
}

// MARK: - Comments

struct ComposerView: View {
    @Binding var text: String
    let title: String
    var submitLabel = "Add comment"
    let onCancel: () -> Void
    let onSubmit: () -> Void
    /// Set when the text can instead be asked as a question, in a new chat.
    var onAsk: (() -> Void)? = nil
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
                    if press.modifiers.contains(.option), let onAsk { onAsk() } else { onSubmit() }
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
                Text("⌘↩ to \(submitLabel.lowercased())\(onAsk == nil ? "" : " · ⌥⌘↩ to ask Claude") · esc to cancel")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button("Cancel", action: onCancel)
                if let onAsk {
                    Button(action: onAsk) {
                        Label("Ask Claude", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .disabled(isEmpty)
                    .help("Ask this as a question in a new chat, instead of adding it as a comment")
                }
                Button(submitLabel, action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: 860, alignment: .leading)
        // A table cell appears before it's in the window, where focus can't land yet.
        .onAppear { DispatchQueue.main.async { focused = true } }
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
                if let selected = comment.selectedText { SelectedTextQuote(text: selected) }
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

/// The exact text a comment refers to when only part of the lines was selected.
struct SelectedTextQuote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(codeFont)
            .lineLimit(6)
            .textSelection(.enabled)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .selectedTextBackgroundColor).opacity(0.5)))
    }
}
