import Foundation

/// What a chat is about: the code that was selected when "Ask Claude" was clicked.
public struct ChatContext: Equatable, Sendable {
    /// Short label for the chat's tab.
    public var title: String
    /// The code, as markdown, quoted in the chat's first message.
    public var description: String
    public var path: String
    /// The first and last rows asked about, to mark them in the diff; nil for a whole file.
    public var startAnchor: LineAnchor?
    public var endAnchor: LineAnchor?
    /// For part of the lines: where the selection starts in the first line and ends in the
    /// last (UTF-16 offsets, as the diff view's selections use). nil for whole lines.
    public var startOffset: Int?
    public var endOffset: Int?

    public init(title: String, description: String, path: String,
                startAnchor: LineAnchor? = nil, endAnchor: LineAnchor? = nil,
                startOffset: Int? = nil, endOffset: Int? = nil) {
        self.title = title
        self.description = description
        self.path = path
        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    public static func lines(path: String, lines: [DiffLine], selectedText: String?,
                             startOffset: Int? = nil, endOffset: Int? = nil) -> ChatContext {
        let isPartial = selectedText?.isEmpty == false
        let comment = ReviewComment.line(path: path, lines: lines, body: "", selectedText: selectedText)
        var description = "`\(path)`, \(comment.rangeLabel.lowercased()):\n\n"
            + MarkdownRenderer.codeBlock(comment.snippet, path: path)
        if let selectedText, !selectedText.isEmpty {
            description += "\n\nSelected text:\n\n"
                + MarkdownRenderer.fenced(selectedText.components(separatedBy: "\n"),
                                          lang: Language.fenceName(forPath: path))
        }
        return ChatContext(title: "\(fileName(path)) · \(comment.rangeLabel)", description: description,
                           path: path, startAnchor: comment.startAnchor, endAnchor: comment.endAnchor,
                           startOffset: isPartial ? startOffset : nil, endOffset: isPartial ? endOffset : nil)
    }

    public static func file(path: String) -> ChatContext {
        ChatContext(title: fileName(path), description: "`\(path)` (the whole file)", path: path)
    }

    /// Files listed in a whole-diff question; past this, the rest are counted.
    static let reviewFileLimit = 200

    /// A question about the whole diff. It names the changed files, so even a fresh session
    /// knows what's under review.
    public static func review(files: [FileDiff]) -> ChatContext {
        var lines = files.prefix(reviewFileLimit).map { "- `\($0.path)` (\(summary(of: $0)))" }
        if files.count > reviewFileLimit { lines.append("- …and \(files.count - reviewFileLimit) more") }
        return ChatContext(title: "Whole diff",
                           description: "the changes as a whole. The files changed are:\n\n" + lines.joined(separator: "\n"),
                           path: "")
    }

    /// "+2 −1", "deleted", "added, +10", "renamed from a.rb, +1 −1".
    private static func summary(of file: FileDiff) -> String {
        if file.status == .deleted { return "deleted" }
        var parts: [String] = []
        switch file.status {
        case .added: parts.append("added")
        case .renamed: if let old = file.oldPath { parts.append("renamed from \(old)") }
        case .copied: if let old = file.oldPath { parts.append("copied from \(old)") }
        case .modified, .deleted: break
        }
        if file.isBinary {
            parts.append("binary")
        } else if file.status == .added {
            // Everything in a new file is added: its size is the count that tells something.
            if file.additions > 0 { parts.append("+\(file.additions)") }
        } else if file.additions + file.deletions > 0 {
            parts.append("+\(file.additions) −\(file.deletions)")
        }
        return parts.isEmpty ? "no content changes" : parts.joined(separator: ", ")
    }

    private static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// The messages sent to Claude. The instructions go in the message rather than the system
/// prompt: a resumed session keeps the system prompt it started with.
public enum ChatPrompt {
    public static func first(question: String, context: ChatContext, reviewing: String) -> String {
        """
        I'm reviewing these changes (\(reviewing)) in diffreview, and I have a question about some \
        of the code. Answer the question. Don't change any files: this is a question, not a \
        request for changes.

        I'm asking about \(context.description)

        Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    public static func followUp(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How `claude` is run for a chat: headless, streaming, and only able to read.
public enum ClaudeCommand {
    public static let tools = "Read,Grep,Glob,Bash"
    public static let allowedTools = "Read,Grep,Glob,Bash(git log *),Bash(git show *),Bash(git diff *)"

    /// - Parameters:
    ///   - resume: the session to continue: the reviewed one (forked) for a chat's first
    ///     message, then the chat's own. nil starts a fresh session.
    ///   - fork: continue a copy of `resume`, leaving that session as it was.
    /// The prompt is written to stdin.
    public static func arguments(resume: String?, fork: Bool) -> [String] {
        // `--tools` limits only Claude Code's own tools; MCP servers (connectors, some of
        // which write) are removed separately.
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", tools, "--allowedTools", allowedTools, "--disallowedTools", "mcp__*"]
        if let resume {
            args += ["--resume", resume]
            if fork { args.append("--fork-session") }
        }
        return args
    }

    /// The app's environment minus what marks it as running inside a Claude Code session, so
    /// `claude` starts as a session of its own. Everything else (PATH, CLAUDE_CONFIG_DIR, auth)
    /// is passed on.
    public static func environment(_ env: [String: String]) -> [String: String] {
        env.filter { $0.key != "CLAUDECODE" && $0.key != "CLAUDE_CODE_SESSION_ID" }
    }

    /// The Claude Code session that opened diffreview: `--session`, or the id Claude Code
    /// sets for commands it runs.
    public static func parentSession(argument: String?, environment: [String: String]) -> String? {
        // "${CLAUDE_SESSION_ID}" arrives as is when Claude Code didn't fill it in.
        if let argument, !argument.isEmpty, !argument.contains("$") { return argument }
        if let id = environment["CLAUDE_CODE_SESSION_ID"], !id.isEmpty { return id }
        return nil
    }

    /// The `claude` executable: on PATH, else where its installers put it. Found directly,
    /// not through a shell, so shell functions or aliases named `claude` don't get in the way.
    public static func locate(environment: [String: String], home: String,
                              isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fallbacks = [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in pathDirs + fallbacks where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("claude")
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

/// What one line of `claude -p --output-format stream-json` output means for a chat.
public enum ClaudeEvent: Equatable, Sendable {
    /// The session the answer belongs to (a fork gets a new one).
    case session(String)
    /// A new assistant message began (Claude answers in several when it uses tools).
    case messageStart
    case text(String)
    /// A tool call, described for the user ("Reading A.swift").
    case tool(String)
    case result(text: String, isError: Bool, session: String?)
}

public enum ClaudeStream {
    public static func parse(_ line: String) -> [ClaudeEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return [] }
            return [.session(id)]
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            if event["type"] as? String == "message_start" { return [.messageStart] }
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return [] }
            return [.text(text)]
        case "assistant":
            // Only a tool call's activity is taken from here; the text already streamed.
            let message = object["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]] ?? []
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                return .tool(describeTool(name: name, input: block["input"] as? [String: Any] ?? [:]))
            }
        case "result":
            let isError = object["is_error"] as? Bool ?? false
            let text = object["result"] as? String
                ?? (object["errors"] as? [String])?.joined(separator: "\n")
                ?? ""
            return [.result(text: text, isError: isError, session: object["session_id"] as? String)]
        default:
            return []
        }
    }

    static func describeTool(name: String, input: [String: Any]) -> String {
        switch name {
        case "Read":
            let path = input["file_path"] as? String ?? ""
            return "Reading \((path as NSString).lastPathComponent)"
        case "Grep", "Glob":
            return "Searching for “\(input["pattern"] as? String ?? "")”"
        case "Bash":
            return "Running \(input["command"] as? String ?? "a command")"
        default:
            return "Using \(name)"
        }
    }
}

/// An answer cut into markdown's blocks, so each can be drawn as what it is. Text inside a
/// block (bold, `code`, links) is left as markdown, for inline styling.
public enum AnswerBlocks {
    public enum Block: Equatable, Sendable {
        /// A paragraph; its line breaks are kept.
        case prose(String)
        case code(String)
        case heading(level: Int, text: String)
        /// `marker` is "•" for a bullet, or the item's number ("2.").
        case listItem(marker: String, depth: Int, text: String)
        case quote(String)
        case rule
        case table(header: [String], rows: [[String]])
    }

    public static func split(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var paragraph: [String] = []
        var quote: [String] = []
        var item: (marker: String, depth: Int, lines: [String])?
        var code: [String] = []
        // The opening fence while inside a code block: closed by a fence at least as long.
        var fence: String?

        func flushText() {
            if !paragraph.isEmpty {
                let prose = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { blocks.append(.prose(prose)) }
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
            if let open = item {
                blocks.append(.listItem(marker: open.marker, depth: open.depth, text: open.lines.joined(separator: "\n")))
                item = nil
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            i += 1
            let backticks = trimmed.prefix { $0 == "`" }.count

            if let open = fence {
                if backticks >= open.count && trimmed.allSatisfy({ $0 == "`" }) {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }
            if backticks >= 3 {
                flushText()
                fence = String(trimmed.prefix(backticks))
                continue
            }
            if trimmed.isEmpty {
                flushText()
                continue
            }
            if let heading = heading(trimmed) {
                flushText()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flushText()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flushText() }
                var rest = trimmed.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                quote.append(String(rest))
                continue
            }
            if trimmed.hasPrefix("|"), i < lines.count, isTableSeparator(lines[i]) {
                flushText()
                let header = cells(trimmed)
                i += 1
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var row = cells(lines[i].trimmingCharacters(in: .whitespaces))
                    // Rows have as many cells as the header: missing ones are empty, extras dropped.
                    row = Array(row.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - row.count))
                    rows.append(row)
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if let next = listItem(line) {
                flushText()
                item = (next.marker, next.depth, [next.text])
                continue
            }
            if item != nil, line.first?.isWhitespace == true {
                item?.lines.append(trimmed)
                continue
            }
            if !quote.isEmpty || item != nil { flushText() }
            paragraph.append(trimmed)
        }
        // An unclosed fence is code still being streamed.
        if fence != nil, !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
        flushText()
        return blocks
    }

    /// "## Title": one to six #s, then a space.
    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        // A closing run of #s ("## Title ##") isn't part of the title.
        var title = rest.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        return .heading(level: hashes, text: title.trimmingCharacters(in: .whitespaces))
    }

    /// "---", "***" or "___": three or more of one of them, spaces allowed between.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// "- item", "* item", "+ item", "1. item" or "1) item", indented two spaces a level.
    private static func listItem(_ line: String) -> (marker: String, depth: Int, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(indent.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return ("•", width / 2, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let punctuation = after.first, punctuation == "." || punctuation == ")",
              after.dropFirst().first == " " else { return nil }
        return (digits + ".", width / 2, after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// The line under a table's header: "|---|:--:|", dashes with optional colons.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        return cells(trimmed).allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// "| a | b |" → ["a", "b"].
    private static func cells(_ line: String) -> [String] {
        var row = Substring(line)
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") { row = row.dropLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Claude's reply to one message, built up from the stream.
public struct ChatAnswer: Equatable, Sendable {
    public var text = ""
    /// Tool calls made while answering, in order.
    public var activity: [String] = []
    public var error: String?
    public var isDone = false

    public init() {}

    public mutating func apply(_ event: ClaudeEvent) {
        switch event {
        case .session:
            break
        case .messageStart:
            if !text.isEmpty && !text.hasSuffix("\n\n") { text += "\n\n" }
        case .text(let delta):
            text += delta
        case .tool(let description):
            activity.append(description)
        case .result(let result, let isError, _):
            if isError {
                error = result.isEmpty ? "Claude couldn't answer." : result
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = result
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            isDone = true
        }
    }
}
