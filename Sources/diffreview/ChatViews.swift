import AppKit
import DiffReviewCore
import SwiftUI

/// Text in the chats, as chosen in Settings. Reading it from a view body makes that view
/// follow changes.
@MainActor private var chatFont: Font { ChatTextSettings.shared.font() }
@MainActor private var chatTheme: ChatTheme { ChatTextSettings.shared.theme }

/// The "Ask Claude" chats, on the right of the diff. Like an accordion: the list of chats,
/// or one chat opened to fill the sidebar, folding back into the list when closed.
struct ChatSidebar: View {
    @Bindable var chats: ChatStore
    /// Scrolls the diff to the code a chat is about.
    let onReveal: (Chat) -> Void
    /// Starts a chat about the whole diff.
    let onAskAboutReview: (String) -> Void

    var body: some View {
        Group {
            if let chat = chats.active {
                ChatView(chats: chats, chat: chat,
                         onCollapse: { withAnimation(.easeOut(duration: 0.15)) { chats.collapse() } })
                    // A fresh view per chat, so scroll position and focus don't carry over.
                    .id(chat.id)
                    .transition(.opacity)
            } else {
                ChatList(chats: chats,
                         onOpen: { chat in
                             withAnimation(.easeOut(duration: 0.15)) { chats.activeID = chat.id }
                             onReveal(chat)
                         },
                         onAskAboutReview: onAskAboutReview)
                    .transition(.opacity)
            }
        }
        .chatThemed(chatTheme)
    }
}

/// Every chat, newest first, with a box at the bottom for asking about the whole diff.
private struct ChatList: View {
    let chats: ChatStore
    let onOpen: (Chat) -> Void
    let onAskAboutReview: (String) -> Void
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(ChatTextSettings.shared.font(scale: 1.05, weight: .semibold))
                Spacer()
                Button {
                    chats.isOpen = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("Hide the chats (⌥⌘C)")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if chats.chats.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Ask about the whole diff below, or select code and use **Ask Claude** in the comment box.")
                        .font(ChatTextSettings.shared.font(scale: 0.9))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chats.chats.reversed()) { chat in
                            ChatRow(chat: chat, onOpen: { onOpen(chat) }, onDelete: { chats.delete(chat) })
                            Divider()
                        }
                    }
                }
            }
            Divider()
            ChatInput(text: $question, placeholder: "Ask about the whole diff…", isRunning: false,
                      focusOnAppear: chats.chats.isEmpty,
                      onSend: {
                          let text = question
                          question = ""
                          onAskAboutReview(text)
                      },
                      onStop: {})
        }
    }
}

/// A folded chat in the list: what it's about and what was asked first.
private struct ChatRow: View {
    let chat: Chat
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.context.title)
                    .font(ChatTextSettings.shared.font(scale: 0.95, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if let first = chat.messages.first(where: { $0.role == .user }) {
                    Text(first.text)
                        .font(ChatTextSettings.shared.font(scale: 0.9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if chat.isRunning {
                ProgressView().controlSize(.small)
            }
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .padding(.top, 3)
            .help("Delete this chat")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.secondary.opacity(hovering ? 0.08 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
    }
}

/// The message box at the bottom of the list and of each chat. ⌘↩ sends.
private struct ChatInput: View {
    @Binding var text: String
    let placeholder: String
    let isRunning: Bool
    var focusOnAppear = true
    let onSend: () -> Void
    let onStop: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $text)
                .font(chatFont)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if !isRunning && !isEmpty { onSend() }
                    return .handled
                }
                .frame(minHeight: 44, maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        // Where TextEditor draws its first line.
                        Text(placeholder).font(chatFont).foregroundStyle(.tertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(chatTheme.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("⌘↩ to send").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if isRunning {
                    Button("Stop", action: onStop)
                } else {
                    Button("Send", action: onSend)
                        .buttonStyle(.borderedProminent)
                        .disabled(isEmpty)
                }
            }
        }
        .padding(10)
        .onAppear {
            if focusOnAppear { DispatchQueue.main.async { focused = true } }
        }
    }
}

private struct ChatView: View {
    let chats: ChatStore
    @Bindable var chat: Chat
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(chat: chat, onCollapse: onCollapse)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ChatTextSettings.shared.paragraphSpacing * 1.8) {
                        ForEach(chat.messages) { message in
                            MessageView(message: message, isRunning: chat.isRunning && message.id == chat.messages.last?.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .onChange(of: chat.messages.last?.answer) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            ChatInput(text: $chat.draft, placeholder: "Ask a follow-up…", isRunning: chat.isRunning,
                      onSend: send, onStop: { chats.stop(chat) })
        }
    }

    private func send() {
        guard !chat.isRunning else { return }
        let text = chat.draft
        chat.draft = ""
        chats.send(text, in: chat)
    }
}

/// The open chat's top bar: a close button back to the list (the code it's about is
/// highlighted in the diff), and a warning when the reviewing session couldn't be forked.
private struct ChatHeader: View {
    let chat: Chat
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Close this chat, back to all chats (esc)")
            }
            if let error = chat.forkError {
                Label {
                    Text("Couldn't fork the Claude Code session that opened this review, so a new session is answering. It can read the code but doesn't know its history. claude said: \(error)")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }
}

private struct MessageView: View {
    let message: Chat.Message
    let isRunning: Bool

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(chatFont)
                .lineSpacing(ChatTextSettings.shared.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(chatTheme.bubble))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 30)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                let answer = message.answer
                if !answer.activity.isEmpty {
                    ActivityList(activity: answer.activity, isRunning: isRunning && answer.text.isEmpty)
                }
                if !answer.text.isEmpty {
                    AnswerText(text: answer.text)
                }
                if let error = answer.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(chatFont).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isRunning && answer.text.isEmpty && answer.activity.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").font(chatFont).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The tools Claude used while answering: the last one, or all of them when expanded.
private struct ActivityList: View {
    let activity: [String]
    let isRunning: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    if isRunning { ProgressView().controlSize(.mini) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                    Text(expanded || activity.count == 1 ? activity[0] : "\(activity.last!) (\(activity.count) steps)")
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(activity.dropFirst().enumerated()), id: \.offset) { _, step in
                    Text(step).lineLimit(1).truncationMode(.middle).padding(.leading, 12)
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

/// Markdown from Claude, block by block: paragraphs, headings, lists, quotes, tables and
/// code. Text inside them gets inline styling (bold, italics, `code`, links).
struct AnswerText: View {
    let text: String

    var body: some View {
        let blocks = AnswerBlocks.split(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : gap(before: block, after: blocks[index - 1]))
            }
        }
    }

    /// List items sit close together; other blocks get a paragraph's space, headings more.
    private func gap(before block: AnswerBlocks.Block, after previous: AnswerBlocks.Block) -> CGFloat {
        let paragraph = ChatTextSettings.shared.paragraphSpacing
        switch (previous, block) {
        case (.listItem, .listItem): return paragraph * 0.35
        case (_, .heading): return paragraph * 1.5
        default: return paragraph
        }
    }

    @ViewBuilder private func view(for block: AnswerBlocks.Block) -> some View {
        switch block {
        case .prose(let prose):
            Self.styled(prose)
        case .heading(let level, let title):
            Text(Self.inline(title))
                .font(ChatTextSettings.shared.font(scale: level == 1 ? 1.35 : level == 2 ? 1.2 : 1.05, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth, let item):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(chatFont)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Self.styled(item)
            }
            .padding(.leading, CGFloat(depth) * 20)
        case .quote(let quote):
            Self.styled(quote)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                }
        case .rule:
            Divider()
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell)).font(ChatTextSettings.shared.font(scale: 0.9, weight: .semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell)).font(ChatTextSettings.shared.font(scale: 0.9))
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .fixedSize()
                .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(chatTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(codeFont)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(chatTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        }
    }

    /// Running text in the chat font.
    private static func styled(_ text: String) -> some View {
        Text(inline(text))
            .font(chatFont)
            .lineSpacing(ChatTextSettings.shared.lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Inline markdown, with `code` in a monospaced font on a tinted background.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var styled = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(size: ChatTextSettings.shared.preference.size * 0.9, design: .monospaced)
            styled[run.range].backgroundColor = Color.secondary.opacity(0.15)
        }
        return styled
    }
}
