import Foundation
import Testing
@testable import DiffReviewCore

@Suite("Arguments: --session")
struct SessionArgumentTests {
    @Test("--session names the Claude Code session to fork chats from")
    func session() throws {
        #expect(try Arguments.parse(["--session", "abc"]).session == "abc")
        #expect(try Arguments.parse(["--session=abc", "--base", "main"])
            == Arguments(mode: .base("main"), session: "abc"))
        #expect(try Arguments.parse([]).session == nil)
    }

    @Test("an empty session (an unsubstituted placeholder) is ignored rather than an error")
    func emptySession() throws {
        #expect(try Arguments.parse(["--session", ""]).session == nil)
        #expect(try Arguments.parse(["--session="]).session == nil)
    }

    @Test("--session without a value is an error")
    func missingValue() {
        #expect(throws: ArgumentError.self) { try Arguments.parse(["--session"]) }
    }
}

@Suite("ChatContext")
struct ChatContextTests {
    @Test("a line selection is described by path and range, with its code")
    func lines() {
        let lines = [DiffLine(kind: .context, text: "let a = 1", oldNumber: 4, newNumber: 4),
                     DiffLine(kind: .addition, text: "let b = 2", oldNumber: nil, newNumber: 5)]
        let context = ChatContext.lines(path: "Sources/A.swift", lines: lines, selectedText: nil)
        #expect(context.title == "A.swift · Lines 4-5 (new)")
        #expect(context.path == "Sources/A.swift")
        #expect(context.startAnchor == LineAnchor(side: .new, line: 4))
        #expect(context.endAnchor == LineAnchor(side: .new, line: 5))
        #expect(context.description == """
            `Sources/A.swift`, lines 4-5 (new):

            ```swift
            let a = 1
            let b = 2
            ```
            """)
    }

    @Test("a partial selection keeps where it starts and ends, to highlight it again")
    func offsets() {
        let lines = [DiffLine(kind: .addition, text: "let value = compute()", oldNumber: nil, newNumber: 9)]
        let partial = ChatContext.lines(path: "a.rb", lines: lines, selectedText: "compute()",
                                        startOffset: 12, endOffset: 21)
        #expect(partial.startOffset == 12 && partial.endOffset == 21)
        // Whole lines have no offsets, even if some were passed.
        let whole = ChatContext.lines(path: "a.rb", lines: lines, selectedText: nil, startOffset: 0, endOffset: 21)
        #expect(whole.startOffset == nil && whole.endOffset == nil)
    }

    @Test("a partial selection adds the exact selected text")
    func partial() {
        let lines = [DiffLine(kind: .addition, text: "let value = compute()", oldNumber: nil, newNumber: 9)]
        let context = ChatContext.lines(path: "a.rb", lines: lines, selectedText: "compute()")
        #expect(context.description.hasSuffix("""
            Selected text:

            ```ruby
            compute()
            ```
            """))
    }

    @Test("a whole-diff context lists the changed files with their counts")
    func review() {
        let files = [
            FileDiff(oldPath: "a.swift", newPath: "a.swift", hunks: [Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 2, lines: [
                DiffLine(kind: .deletion, text: "x", oldNumber: 1, newNumber: nil),
                DiffLine(kind: .addition, text: "y", oldNumber: nil, newNumber: 1),
                DiffLine(kind: .addition, text: "z", oldNumber: nil, newNumber: 2),
            ])]),
            FileDiff(oldPath: "old.rb", newPath: nil, status: .deleted),
        ]
        let context = ChatContext.review(files: files)
        #expect(context.title == "Whole diff")
        #expect(context.path.isEmpty)
        #expect(context.startAnchor == nil)
        #expect(context.description == """
            the changes as a whole. The files changed are:

            - `a.swift` (+2 −1)
            - `old.rb` (deleted)
            """)
    }

    @Test("a long file list is cut short with a count of the rest")
    func longReview() {
        let files = (1...205).map { FileDiff(oldPath: nil, newPath: "f\($0).txt", status: .added) }
        let description = ChatContext.review(files: files).description
        #expect(description.contains("- `f200.txt` (added)"))
        #expect(!description.contains("f201.txt"))
        #expect(description.hasSuffix("- …and 5 more"))
    }

    @Test("a file context names just the file")
    func file() {
        let context = ChatContext.file(path: "lib/x.rb")
        #expect(context.title == "x.rb")
        #expect(context.description == "`lib/x.rb` (the whole file)")
        #expect(context.path == "lib/x.rb")
        #expect(context.startAnchor == nil && context.endAnchor == nil)
    }
}

@Suite("ChatPrompt")
struct ChatPromptTests {
    let context = ChatContext.file(path: "lib/x.rb")

    @Test("the first message frames the question, says not to change files, and quotes the code")
    func first() {
        let prompt = ChatPrompt.first(question: "  Why is this here?\n", context: context, reviewing: "Uncommitted changes")
        #expect(prompt.contains("diffreview"))
        #expect(prompt.contains("Uncommitted changes"))
        #expect(prompt.contains("Don't change any files"))
        #expect(prompt.contains("I'm asking about `lib/x.rb` (the whole file)"))
        #expect(prompt.hasSuffix("Question: Why is this here?"))
    }

    @Test("a whole-diff question reads as being about the changes")
    func review() {
        let prompt = ChatPrompt.first(question: "Is this safe?", context: .review(files: []), reviewing: "Changes since main")
        #expect(prompt.contains("I'm asking about the changes as a whole."))
    }

    @Test("follow-ups are sent as typed, trimmed")
    func followUp() {
        #expect(ChatPrompt.followUp("  and this?  ") == "and this?")
    }
}

@Suite("ClaudeCommand")
struct ClaudeCommandTests {
    @Test("the first message of a chat forks the reviewed session")
    func forks() {
        let args = ClaudeCommand.arguments(resume: "parent-1", fork: true)
        #expect(args.starts(with: ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]))
        #expect(adjacent(args, "--resume", "parent-1"))
        #expect(args.contains("--fork-session"))
        #expect(adjacent(args, "--tools", "Read,Grep,Glob,Bash"))
        #expect(adjacent(args, "--allowedTools", "Read,Grep,Glob,Bash(git log *),Bash(git show *),Bash(git diff *)"))
    }

    @Test("MCP tools (connectors, some of which write) are taken away, since --tools only limits built-in ones")
    func noMCP() {
        #expect(adjacent(ClaudeCommand.arguments(resume: nil, fork: true), "--disallowedTools", "mcp__*"))
        #expect(adjacent(ClaudeCommand.arguments(resume: "s", fork: false), "--disallowedTools", "mcp__*"))
    }

    @Test("a follow-up resumes the chat's own session without forking again")
    func followUp() {
        let args = ClaudeCommand.arguments(resume: "chat-1", fork: false)
        #expect(adjacent(args, "--resume", "chat-1"))
        #expect(!args.contains("--fork-session"))
    }

    @Test("with no session to resume, a fresh session starts")
    func fresh() {
        let args = ClaudeCommand.arguments(resume: nil, fork: true)
        #expect(!args.contains("--resume"))
        #expect(!args.contains("--fork-session"))
    }

    @Test("the environment drops the markers of the Claude Code session that launched diffreview")
    func environment() {
        let env = ClaudeCommand.environment(["PATH": "/bin", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x",
                                             "CLAUDE_CONFIG_DIR": "/c"])
        #expect(env == ["PATH": "/bin", "CLAUDE_CONFIG_DIR": "/c"])
    }

    @Test("the session to fork comes from --session, else from the environment")
    func parentSession() {
        #expect(ClaudeCommand.parentSession(argument: "a", environment: ["CLAUDE_CODE_SESSION_ID": "b"]) == "a")
        #expect(ClaudeCommand.parentSession(argument: nil, environment: ["CLAUDE_CODE_SESSION_ID": "b"]) == "b")
        #expect(ClaudeCommand.parentSession(argument: nil, environment: ["CLAUDE_CODE_SESSION_ID": ""]) == nil)
        #expect(ClaudeCommand.parentSession(argument: nil, environment: [:]) == nil)
    }

    @Test("a placeholder that wasn't filled in isn't taken for a session id")
    func placeholder() {
        #expect(ClaudeCommand.parentSession(argument: "${CLAUDE_SESSION_ID}", environment: [:]) == nil)
        #expect(ClaudeCommand.parentSession(argument: "${CLAUDE_SESSION_ID}",
                                            environment: ["CLAUDE_CODE_SESSION_ID": "b"]) == "b")
    }

    @Test("claude is found on PATH first, then in the usual install locations")
    func locate() {
        let home = "/Users/me"
        let onPath = ClaudeCommand.locate(environment: ["PATH": "/usr/bin:/opt/x/bin"], home: home) {
            $0 == "/opt/x/bin/claude" || $0 == "/Users/me/.local/bin/claude"
        }
        #expect(onPath == "/opt/x/bin/claude")
        let fallback = ClaudeCommand.locate(environment: ["PATH": "/usr/bin"], home: home) {
            $0 == "/Users/me/.local/bin/claude"
        }
        #expect(fallback == "/Users/me/.local/bin/claude")
        #expect(ClaudeCommand.locate(environment: [:], home: home) { _ in false } == nil)
    }

    private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return false }
        return args[i + 1] == value
    }
}

@Suite("ClaudeStream")
struct ClaudeStreamTests {
    @Test("the init event gives the session id")
    func initEvent() {
        #expect(ClaudeStream.parse(#"{"type":"system","subtype":"init","session_id":"s1","tools":[]}"#)
            == [.session("s1")])
    }

    @Test("text deltas stream the answer")
    func delta() {
        let line = #"{"type":"stream_event","session_id":"s1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#
        #expect(ClaudeStream.parse(line) == [.text("Hel")])
    }

    @Test("a new assistant message after the first starts a new paragraph")
    func messageStart() {
        let line = #"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#
        #expect(ClaudeStream.parse(line) == [.messageStart])
    }

    @Test("tool calls in an assistant message are reported as activity")
    func toolUse() {
        let line = #"""
        {"type":"assistant","session_id":"s1","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"/repo/Sources/A.swift"}},{"type":"tool_use","id":"u","name":"Grep","input":{"pattern":"foo"}},{"type":"tool_use","id":"v","name":"Bash","input":{"command":"git log -3"}}]}}
        """#
        #expect(ClaudeStream.parse(line) == [.tool("Reading A.swift"), .tool("Searching for “foo”"),
                                             .tool("Running git log -3")])
    }

    @Test("the result ends the turn, successfully or not")
    func result() {
        #expect(ClaudeStream.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"s2"}"#)
            == [.result(text: "Done.", isError: false, session: "s2")])
        #expect(ClaudeStream.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom","bang"],"session_id":"s2"}"#)
            == [.result(text: "boom\nbang", isError: true, session: "s2")])
    }

    @Test("blank, malformed and unknown lines are ignored")
    func ignored() {
        #expect(ClaudeStream.parse("").isEmpty)
        #expect(ClaudeStream.parse("not json").isEmpty)
        #expect(ClaudeStream.parse(#"{"type":"user","message":{}}"#).isEmpty)
    }
}

@Suite("AnswerBlocks")
struct AnswerBlocksTests {
    @Test("fenced code is split out of the prose around it")
    func split() {
        let text = """
            It's called here:

            ```swift
            foo()
              bar()
            ```

            And that's it.
            """
        #expect(AnswerBlocks.split(text) == [.prose("It's called here:"), .code("foo()\n  bar()"),
                                             .prose("And that's it.")])
    }

    @Test("prose alone is one block; an unclosed fence (still streaming) is code so far")
    func edges() {
        #expect(AnswerBlocks.split("Just text.") == [.prose("Just text.")])
        #expect(AnswerBlocks.split("See:\n```rb\nx = 1") == [.prose("See:"), .code("x = 1")])
        #expect(AnswerBlocks.split("").isEmpty)
    }

    @Test("a longer fence can hold a shorter one")
    func nested() {
        #expect(AnswerBlocks.split("````md\n```\ninner\n```\n````") == [.code("```\ninner\n```")])
    }

    @Test("headings keep their level")
    func headings() {
        #expect(AnswerBlocks.split("## Why\nBecause.\n\n### Details") == [
            .heading(level: 2, text: "Why"), .prose("Because."), .heading(level: 3, text: "Details"),
        ])
        #expect(AnswerBlocks.split("#hashtag") == [.prose("#hashtag")])
    }

    @Test("bullets and numbered items are list items, nested by indentation")
    func lists() {
        let text = """
            Two reasons:
            - first
              - nested
            * second
            1. one
            2) two
            """
        #expect(AnswerBlocks.split(text) == [
            .prose("Two reasons:"),
            .listItem(marker: "•", depth: 0, text: "first"),
            .listItem(marker: "•", depth: 1, text: "nested"),
            .listItem(marker: "•", depth: 0, text: "second"),
            .listItem(marker: "1.", depth: 0, text: "one"),
            .listItem(marker: "2.", depth: 0, text: "two"),
        ])
    }

    @Test("an indented line under a list item continues it")
    func listContinuation() {
        #expect(AnswerBlocks.split("- first line\n  more of it\n\nAfter.") == [
            .listItem(marker: "•", depth: 0, text: "first line\nmore of it"), .prose("After."),
        ])
    }

    @Test("quotes are merged across lines, and rules stand alone")
    func quotesAndRules() {
        #expect(AnswerBlocks.split("> one\n> two\n\n---\n\nend") == [.quote("one\ntwo"), .rule, .prose("end")])
    }

    @Test("a table becomes a header and rows of cells")
    func table() {
        let text = """
            | Name | Kind |
            |------|:----:|
            | `a`  | int  |
            | b    |      |
            Text after.
            """
        #expect(AnswerBlocks.split(text) == [
            .table(header: ["Name", "Kind"], rows: [["`a`", "int"], ["b", ""]]),
            .prose("Text after."),
        ])
    }

    @Test("pipes without a separator line are just prose")
    func notATable() {
        #expect(AnswerBlocks.split("| not | a table |") == [.prose("| not | a table |")])
    }
}

@Suite("ChatTranscript")
struct ChatTranscriptTests {
    @Test("an answer accumulates deltas, with a paragraph break between assistant messages")
    func accumulate() {
        var answer = ChatAnswer()
        answer.apply(.messageStart)
        answer.apply(.text("Let me "))
        answer.apply(.text("check."))
        answer.apply(.tool("Reading A.swift"))
        answer.apply(.messageStart)
        answer.apply(.text("It's for X."))
        #expect(answer.text == "Let me check.\n\nIt's for X.")
        #expect(answer.activity == ["Reading A.swift"])
        #expect(!answer.isDone)
        answer.apply(.result(text: "It's for X.", isError: false, session: "s"))
        #expect(answer.isDone)
        #expect(answer.error == nil)
    }

    @Test("with no streamed text, the result is the answer")
    func resultOnly() {
        var answer = ChatAnswer()
        answer.apply(.result(text: "Short answer.", isError: false, session: "s"))
        #expect(answer.text == "Short answer.")
    }

    @Test("an error result is kept as the error")
    func error() {
        var answer = ChatAnswer()
        answer.apply(.result(text: "Not logged in", isError: true, session: nil))
        #expect(answer.error == "Not logged in")
        #expect(answer.isDone)
    }
}
