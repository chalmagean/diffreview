import Foundation
import Testing
@testable import DiffReviewCore

@Suite("Syntax highlighting")
struct SyntaxTests {
    /// The line's coloured pieces, as (text, kind).
    private func pieces(_ line: String, _ language: String) -> [(String, SyntaxKind)] {
        var state = SyntaxState.normal
        return pieces(line, language, state: &state)
    }

    private func pieces(_ line: String, _ language: String, state: inout SyntaxState) -> [(String, SyntaxKind)] {
        let syntax = Syntax(language: language)!
        let text = line as NSString
        return syntax.tokenize(line, state: &state).map {
            (text.substring(with: NSRange(location: $0.location, length: $0.length)), $0.kind)
        }
    }

    private func kind(of word: String, in line: String, _ language: String) -> SyntaxKind? {
        pieces(line, language).first { $0.0 == word }?.1
    }

    @Test("unknown languages aren't highlighted")
    func unknown() {
        #expect(Syntax(language: "") == nil)
        #expect(Syntax(language: "no-such-language") == nil)
    }

    @Test("keywords, strings, numbers, types and calls in Swift")
    func swift() {
        let line = #"let x: Int = compute("hi", 42) // done"#
        #expect(kind(of: "let", in: line, "swift") == .keyword)
        #expect(kind(of: "Int", in: line, "swift") == .type)
        #expect(kind(of: "compute", in: line, "swift") == .function)
        #expect(kind(of: #""hi""#, in: line, "swift") == .string)
        #expect(kind(of: "42", in: line, "swift") == .constant)
        #expect(kind(of: "// done", in: line, "swift") == .comment)
        #expect(kind(of: "x", in: line, "swift") == nil)
    }

    @Test("escaped quotes don't end a string")
    func escapes() {
        #expect(pieces(#"s = "a \" b" + c"#, "ruby").first { $0.1 == .string }?.0 == #""a \" b""#)
    }

    @Test("Ruby comments, symbols and instance variables")
    func ruby() {
        let line = "  def call(@name, :sym) # note"
        #expect(kind(of: "def", in: line, "ruby") == .keyword)
        #expect(kind(of: "@name", in: line, "ruby") == .constant)
        #expect(kind(of: ":sym", in: line, "ruby") == .constant)
        #expect(kind(of: "# note", in: line, "ruby") == .comment)
        // A namespace separator isn't a symbol.
        #expect(kind(of: ":Bar", in: "Foo::Bar", "ruby") == nil)
    }

    @Test("a block comment carries over to the next lines until it closes")
    func blockComment() {
        var state = SyntaxState.normal
        #expect(pieces("x = 1 /* start", "javascript", state: &state).last?.1 == .comment)
        #expect(pieces("still comment", "javascript", state: &state).map(\.1) == [.comment])
        let last = pieces("end */ return y", "javascript", state: &state)
        #expect(last.first?.0 == "end */" && last.first?.1 == .comment)
        #expect(last.contains { $0.0 == "return" && $0.1 == .keyword })
        #expect(state == .normal)
    }

    @Test("a triple-quoted string spans lines")
    func multilineString() {
        var state = SyntaxState.normal
        _ = pieces(#"doc = """"#, "python", state: &state)
        #expect(pieces("def not_code", "python", state: &state).map(\.1) == [.string])
        _ = pieces(#"""""#, "python", state: &state)
        #expect(kind(of: "def", in: "def f():", "python") == .keyword)
        #expect(state == .normal)
    }

    @Test("an unclosed quote on one line is left alone (an apostrophe, a Rust lifetime)")
    func unclosedQuote() {
        let line = "fn f<'a>(x: &'a str) -> u8"
        #expect(kind(of: "fn", in: line, "rust") == .keyword)
        #expect(!pieces(line, "rust").contains { $0.1 == .string })
    }

    @Test("JSON and YAML keys stand out from their values")
    func keys() {
        #expect(kind(of: #""name""#, in: #"  "name": "x","#, "json") == .constant)
        #expect(kind(of: #""x""#, in: #"  "name": "x","#, "json") == .string)
        #expect(kind(of: "name", in: "name: value # c", "yaml") == .constant)
        #expect(kind(of: "# c", in: "name: value # c", "yaml") == .comment)
    }

    @Test("HTML tags")
    func html() {
        let line = #"<div class="a">text</div>"#
        #expect(kind(of: "div", in: line, "html") == .tag)
        #expect(kind(of: #""a""#, in: line, "html") == .string)
        #expect(kind(of: "text", in: line, "html") == nil)
    }

    @Test("a shell # inside a word isn't a comment")
    func shellHash() {
        #expect(!pieces("echo ${#items} a#b", "bash").contains { $0.1 == .comment })
        #expect(kind(of: "# real", in: "ls # real", "bash") == .comment)
    }

    @Test("offsets are UTF-16, so they line up with the text view")
    func utf16() {
        var state = SyntaxState.normal
        let tokens = Syntax(language: "swift")!.tokenize(#"let é = "🎉" // c"#, state: &state)
        let comment = tokens.first { $0.kind == .comment }!
        #expect(comment.location == ("let é = \"🎉\" " as NSString).length)
    }

    @Test("diff lines are highlighted per side: an open comment on the old side doesn't leak into the new")
    func diffSides() {
        var hunk = Hunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2)
        hunk.lines = [
            DiffLine(kind: .deletion, text: "/* old", oldNumber: 1, newNumber: nil),
            DiffLine(kind: .addition, text: "let a = 1", oldNumber: nil, newNumber: 1),
            DiffLine(kind: .deletion, text: "still old */", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .addition, text: "let b = 2", oldNumber: nil, newNumber: 2),
        ]
        let tokens = Syntax.tokenize(hunks: [hunk], language: "swift")
        #expect(tokens.count == 4)
        #expect(tokens[1].first?.kind == .keyword)
        #expect(tokens[2].map(\.kind) == [.comment])
        #expect(tokens[3].first?.kind == .keyword)
    }

    @Test("an unknown language gives no tokens, one empty list per line")
    func unknownLines() {
        #expect(Syntax.tokenize(lines: ["a", "b"], language: "") == [[], []])
    }
}
