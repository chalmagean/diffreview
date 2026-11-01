import Foundation
import Testing
@testable import DiffReviewCore

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -40,5 +40,6 @@
     let a = 1
     let b = 2
    -let c = 3
    +let c = 4
    +let d = 5
     let e = 6
     let f = 7
    diff --git a/old.rb b/new.rb
    similarity index 90%
    rename from old.rb
    rename to new.rb
    --- a/old.rb
    +++ b/new.rb
    @@ -1 +1 @@
    -puts 1
    +puts 2

    """

    var files: [FileDiff] { DiffParser.parse(diff) }

    @Test("comment created from additions and context uses the new side")
    func newSideRange() throws {
        let lines = files[0].allLines
        // let b (ctx, new 41), -let c (old 42), +let c (new 42), +let d (new 43)
        let c = ReviewComment.line(path: files[0].path, lines: Array(lines[3...4]), body: "x")
        #expect(c.side == .new)
        #expect(c.startLine == 42 && c.endLine == 43)
        #expect(c.startAnchor == LineAnchor(side: .new, line: 42))
        #expect(c.endAnchor == LineAnchor(side: .new, line: 43))
        #expect(c.rangeLabel == "Lines 42-43 (new)")
        #expect(c.isFileLevel == false)
    }

    @Test("comment on only deletions uses the old side")
    func oldSide() throws {
        let c = ReviewComment.line(path: "f", lines: [files[0].allLines[2]], body: "x")
        #expect(c.side == .old)
        #expect(c.rangeLabel == "Line 42 (old)")
        #expect(c.endAnchor == LineAnchor(side: .old, line: 42))
    }

    @Test("mixed range anchors to rows but labels by new-side numbers")
    func mixed() throws {
        let lines = files[0].allLines
        let c = ReviewComment.line(path: "f", lines: Array(lines[1...3]), body: "x")
        #expect(c.side == .new)
        #expect(c.startLine == 41 && c.endLine == 42)
        #expect(c.startAnchor == LineAnchor(side: .new, line: 41))
        #expect(c.endAnchor == LineAnchor(side: .new, line: 42))
        #expect(c.snippet.map(\.kind) == [.context, .deletion, .addition])
    }

    @Test("renders the full review grouped by file in diff order")
    func fullRender() throws {
        let files = self.files
        let lines = files[0].allLines
        var draft = ReviewDraft()
        draft.summary = "Looks mostly good.\n"
        // Added out of order on purpose.
        draft.comments = [
            ReviewComment.line(path: "new.rb", lines: [files[1].allLines[1]], body: "Why 2?"),
            ReviewComment.line(path: files[0].path, lines: Array(lines[5...6]), body: "Second"),
            ReviewComment.line(path: files[0].path, lines: Array(lines[3...4]), body: "Rename these."),
            ReviewComment.file(path: files[0].path, body: "File-level note."),
        ]
        let md = MarkdownRenderer.render(draft: draft, files: files)
        let expected = """
        # Code Review

        Looks mostly good.

        ## Sources/App.swift

        File-level note.

        ### Lines 42-43 (new)

        ```swift
        let c = 4
        let d = 5
        ```

        Rename these.

        ### Lines 44-45 (new)

        ```swift
        let e = 6
        let f = 7
        ```

        Second

        ## new.rb (renamed from old.rb)

        ### Line 1 (new)

        ```ruby
        puts 2
        ```

        Why 2?

        """
        #expect(md == expected)
    }

    @Test("mixed snippets render as a diff block")
    func diffSnippet() throws {
        let lines = files[0].allLines
        var draft = ReviewDraft()
        draft.comments = [ReviewComment.line(path: files[0].path, lines: Array(lines[2...3]), body: "Hmm")]
        let md = MarkdownRenderer.render(draft: draft, files: files)
        #expect(md.contains("### Line 42 (new)\n\n```diff\n-let c = 3\n+let c = 4\n```\n\nHmm\n"))
    }

    @Test("snippets containing backtick fences get a longer fence")
    func fenceEscaping() {
        var draft = ReviewDraft()
        let line = DiffLine(kind: .addition, text: "```swift", oldNumber: nil, newNumber: 3)
        draft.comments = [ReviewComment.line(path: "README.md", lines: [line], body: "b")]
        let md = MarkdownRenderer.render(draft: draft, files: [])
        #expect(md.contains("````markdown\n```swift\n````"))
    }

    @Test("comments on files no longer in the diff are still output")
    func staleFile() {
        var draft = ReviewDraft()
        draft.comments = [ReviewComment.file(path: "gone.txt", body: "still matters")]
        let md = MarkdownRenderer.render(draft: draft, files: [])
        #expect(md == "# Code Review\n\n## gone.txt\n\nstill matters\n")
    }

    @Test("empty review")
    func emptyReview() {
        let md = MarkdownRenderer.render(draft: ReviewDraft(), files: [])
        #expect(md == "# Code Review\n\nNo comments.\n")
    }

    @Test("blank comments are skipped")
    func blankComments() {
        var draft = ReviewDraft()
        draft.summary = "   "
        draft.comments = [ReviewComment.file(path: "a", body: "  \n ")]
        #expect(MarkdownRenderer.render(draft: draft, files: []) == "# Code Review\n\nNo comments.\n")
    }

    @Test("CR is stripped from snippets, tabs kept")
    func cleanSnippet() {
        var draft = ReviewDraft()
        let line = DiffLine(kind: .addition, text: "\tx\r", oldNumber: nil, newNumber: 1)
        draft.comments = [ReviewComment.line(path: "a.go", lines: [line], body: "b")]
        let md = MarkdownRenderer.render(draft: draft, files: [])
        #expect(md.contains("```go\n\tx\n```"))
    }
}

@Suite("Language")
struct LanguageTests {
    @Test func detection() {
        #expect(Language.fenceName(forPath: "a/b/c.swift") == "swift")
        #expect(Language.fenceName(forPath: "app/models/user.rb") == "ruby")
        #expect(Language.fenceName(forPath: "Gemfile") == "ruby")
        #expect(Language.fenceName(forPath: "x.tsx") == "tsx")
        #expect(Language.fenceName(forPath: "Makefile") == "makefile")
        #expect(Language.fenceName(forPath: "noext") == "")
    }
}

@Suite("DraftStore")
struct DraftStoreTests {
    @Test("round trip and clear")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffreview-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DraftStore(gitDir: dir)
        #expect(store.url.path.hasSuffix("diffreview/comments.json"))
        #expect(store.load() == nil)

        var draft = ReviewDraft()
        draft.summary = "sum"
        draft.comments = [ReviewComment.file(path: "a", body: "b")]
        try store.save(draft)
        #expect(store.load() == draft)

        store.clear()
        #expect(store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test("corrupt file loads as nil")
    func corrupt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffreview-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DraftStore(gitDir: dir)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: store.url)
        #expect(store.load() == nil)
    }
}
