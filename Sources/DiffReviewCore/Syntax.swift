import Foundation

/// What a highlighted piece of code is. Kept to a few kinds, each with its own colour.
public enum SyntaxKind: Sendable, Hashable {
    case keyword, string, comment
    /// Numbers, literals like `true`/`nil`, symbols, sigil variables, attributes and keys.
    case constant
    case type
    /// A name that's called, and decorators.
    case function
    /// A markup tag name.
    case tag
}

/// A highlighted range of one line, in UTF-16 offsets (as the text view lays the line out).
public struct SyntaxToken: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxKind

    public init(location: Int, length: Int, kind: SyntaxKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

/// What carries over from the end of one line to the next.
public enum SyntaxState: Hashable, Sendable {
    case normal
    /// Inside the grammar's block comment with this index.
    case blockComment(Int)
    /// Inside the grammar's multi-line string with this index.
    case string(Int)
}

/// A small line-by-line highlighter: keywords, strings, comments, numbers and a few
/// language-specific marks. Not a parser; it aims to make code easy to read, not to be exact.
public struct Syntax: Sendable {
    let grammar: Grammar

    /// nil when the language (a `Language.fenceName`) isn't known.
    public init?(language: String) {
        guard let grammar = Grammar.forLanguage(language) else { return nil }
        self.grammar = grammar
    }

    /// The tokens of each line, read in order as one piece of code.
    public static func tokenize(lines: [String], language: String) -> [[SyntaxToken]] {
        guard let syntax = Syntax(language: language) else { return lines.map { _ in [] } }
        var state = SyntaxState.normal
        return lines.map { syntax.tokenize($0, state: &state) }
    }

    /// The tokens of each diff line, flattened across hunks. The old side (context and
    /// deletions) and the new side (context and additions) are each read as code of their
    /// own, so something left open on one side doesn't colour the other. Each hunk starts afresh.
    public static func tokenize(hunks: [Hunk], language: String) -> [[SyntaxToken]] {
        guard let syntax = Syntax(language: language) else {
            return hunks.flatMap { $0.lines.map { _ in [] } }
        }
        var result: [[SyntaxToken]] = []
        for hunk in hunks {
            var old = SyntaxState.normal
            var new = SyntaxState.normal
            for line in hunk.lines {
                switch line.kind {
                case .deletion:
                    result.append(syntax.tokenize(line.text, state: &old))
                case .addition:
                    result.append(syntax.tokenize(line.text, state: &new))
                case .context:
                    var fromOld = old
                    _ = syntax.tokenize(line.text, state: &fromOld)
                    result.append(syntax.tokenize(line.text, state: &new))
                    old = fromOld
                }
            }
        }
        return result
    }

    /// Tokens of one line, given what the previous line left open; updates `state` for the next.
    public func tokenize(_ line: String, state: inout SyntaxState) -> [SyntaxToken] {
        var scanner = Scanner(grammar: grammar, text: Array(line.utf16))
        scanner.run(&state)
        return scanner.tokens
    }
}

// MARK: - Scanning

private struct Scanner {
    let grammar: Grammar
    let text: [UInt16]
    var i = 0
    var tokens: [SyntaxToken] = []

    init(grammar: Grammar, text: [UInt16]) {
        self.grammar = grammar
        // A trailing CR isn't part of the laid-out line.
        self.text = text.last == 13 ? Array(text.dropLast()) : text
    }

    mutating func run(_ state: inout SyntaxState) {
        switch state {
        case .normal: break
        case .blockComment(let k):
            if !finishBlockComment(grammar.blockComments[k], from: 0) { return }
            state = .normal
        case .string(let k):
            if !finishString(grammar.strings[k], from: 0) { return }
            state = .normal
        }
        while i < text.count {
            if let next = step() {
                state = next
                return
            }
        }
    }

    /// Reads one thing at `i`. Returns a state when it runs off the end of the line open.
    private mutating func step() -> SyntaxState? {
        let c = text[i]
        if c == 32 || c == 9 { i += 1; return nil }

        for (k, pair) in grammar.blockComments.enumerated() where matches(pair.open, at: i) {
            let start = i
            i += pair.open.count
            if !finishBlockComment(pair, from: start) { return .blockComment(k) }
            return nil
        }
        for prefix in grammar.lineComments where matches(prefix, at: i) {
            if grammar.hashNeedsSpace, prefix == [35], i > 0, !isSpace(text[i - 1]) { break }
            add(i, text.count - i, .comment)
            i = text.count
            return nil
        }
        for (k, string) in grammar.strings.enumerated() where matches(string.delimiter, at: i) {
            let start = i
            if string.charLiteral {
                // One character (or an escape) between quotes; otherwise a lifetime like `'a`.
                guard let end = charLiteralEnd(from: i) else { i += 1; return nil }
                add(start, end - start, .string)
                i = end
                return nil
            }
            i += string.delimiter.count
            if finishString(string, from: start) {
                markKey(tokenAt: tokens.count - 1)
                return nil
            }
            if string.multiline { return .string(k) }
            // Unclosed on its line: an apostrophe or a lifetime, not a string.
            tokens.removeLast()
            i = start + string.delimiter.count
            return nil
        }
        if grammar.markup, c == 60 /* < */ { return readTag() }
        if isDigit(c) || (c == 46 && i + 1 < text.count && isDigit(text[i + 1])) {
            readNumber()
            return nil
        }
        if let kind = grammar.sigils[c], i + 1 < text.count, isIdentifierStart(text[i + 1]),
           sigilAllowed(c) {
            let start = i
            i += 1
            readIdentifierBody()
            add(start, i - start, kind)
            return nil
        }
        if isIdentifierStart(c) {
            readWord()
            return nil
        }
        i += 1
        return nil
    }

    // MARK: Pieces

    /// Scans to the end of a block comment begun at `start`; false when it doesn't end on this line.
    private mutating func finishBlockComment(_ pair: Grammar.Pair, from start: Int) -> Bool {
        while i < text.count {
            if matches(pair.close, at: i) {
                i += pair.close.count
                add(start, i - start, .comment)
                return true
            }
            i += 1
        }
        add(start, text.count - start, .comment)
        return false
    }

    /// Scans to the closing delimiter of a string begun at `start`; false when it doesn't close.
    private mutating func finishString(_ string: Grammar.StringRule, from start: Int) -> Bool {
        while i < text.count {
            if string.escapes, text[i] == 92 /* \ */ { i += 2; continue }
            if matches(string.delimiter, at: i) {
                i += string.delimiter.count
                add(start, i - start, .string)
                return true
            }
            i += 1
        }
        i = text.count
        add(start, text.count - start, .string)
        return false
    }

    /// The end of a char literal `'x'`, `'\n'` or `'\u{1F600}'` starting at `start`, if it is one.
    private func charLiteralEnd(from start: Int) -> Int? {
        var j = start + 1
        guard j < text.count else { return nil }
        if text[j] == 92 /* \ */ {
            j += 2
            while j < text.count, text[j] != 39, j - start < 12 { j += 1 }
        } else {
            // A surrogate pair is one character.
            j += UTF16.isLeadSurrogate(text[j]) ? 2 : 1
        }
        return j < text.count && text[j] == 39 ? j + 1 : nil
    }

    private mutating func readNumber() {
        let start = i
        while i < text.count {
            let c = text[i]
            if isIdentifierChar(c) { i += 1; continue }
            if c == 46, i + 1 < text.count, isDigit(text[i + 1]) { i += 1; continue }
            break
        }
        add(start, i - start, .constant)
    }

    private mutating func readIdentifierBody() {
        while i < text.count, isIdentifierChar(text[i]) { i += 1 }
        // Ruby's predicate and bang methods.
        if grammar.wordSuffixes, i < text.count, text[i] == 63 || text[i] == 33,
           !(i + 1 < text.count && text[i + 1] == 61) { i += 1 }
    }

    private mutating func readWord() {
        let start = i
        readIdentifierBody()
        let word = String(decoding: text[start..<i], as: UTF16.self)
        let length = i - start
        if grammar.keywords.contains(word) {
            add(start, length, .keyword)
        } else if grammar.constants.contains(word) {
            add(start, length, .constant)
        } else if isKey(after: i) {
            add(start, length, .constant)
        } else if grammar.types.contains(word) || (grammar.capitalizedTypes && isUpper(text[start])) {
            add(start, length, .type)
        } else if grammar.calls, nextNonSpace(from: i) == 40 /* ( */ {
            add(start, length, .function)
        }
    }

    /// `<name`, `</name`: the name is a tag. Attributes inside are read as words and strings.
    private mutating func readTag() -> SyntaxState? {
        var j = i + 1
        if j < text.count, text[j] == 47 /* / */ { j += 1 }
        guard j < text.count, isIdentifierStart(text[j]) else { i += 1; return nil }
        let start = j
        i = j
        while i < text.count, isIdentifierChar(text[i]) || text[i] == 58 /* : */ { i += 1 }
        add(start, i - start, .tag)
        return nil
    }

    // MARK: Keys

    /// In grammars with keys (JSON, YAML, TOML, CSS), a word or string followed by the key
    /// delimiter is a key.
    private func isKey(after end: Int) -> Bool {
        guard !grammar.keyDelimiters.isEmpty, let next = nextNonSpaceIndex(from: end) else { return false }
        guard grammar.keyDelimiters.contains(text[next]) else { return false }
        // A colon followed by more of a word is a selector or scheme (`a:hover`, `http://`).
        if text[next] == 58, next + 1 < text.count, !isSpace(text[next + 1]), grammar.keyColonNeedsSpace { return false }
        return true
    }

    private mutating func markKey(tokenAt index: Int) {
        guard index >= 0, tokens[index].kind == .string, isKey(after: i) else { return }
        tokens[index].kind = .constant
    }

    // MARK: Helpers

    private mutating func add(_ location: Int, _ length: Int, _ kind: SyntaxKind) {
        guard length > 0 else { return }
        tokens.append(SyntaxToken(location: location, length: length, kind: kind))
    }

    private func matches(_ pattern: [UInt16], at index: Int) -> Bool {
        guard !pattern.isEmpty, index + pattern.count <= text.count else { return false }
        for (k, u) in pattern.enumerated() where text[index + k] != u { return false }
        return true
    }

    /// A Ruby symbol `:name` isn't `a::b` or the middle of `a ? b :c`... close enough: not after
    /// a word or another colon.
    private func sigilAllowed(_ c: UInt16) -> Bool {
        guard c == 58 /* : */ else { return true }
        guard i > 0 else { return true }
        let before = text[i - 1]
        return !(isIdentifierChar(before) || before == 58)
    }

    private func nextNonSpaceIndex(from index: Int) -> Int? {
        var j = index
        while j < text.count, isSpace(text[j]) { j += 1 }
        return j < text.count ? j : nil
    }

    private func nextNonSpace(from index: Int) -> UInt16? {
        nextNonSpaceIndex(from: index).map { text[$0] }
    }

    private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 }
    private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private func isUpper(_ c: UInt16) -> Bool { c >= 65 && c <= 90 }

    private func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
            || (grammar.dollarInIdentifiers && c == 36)
    }

    private func isIdentifierChar(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || isDigit(c) || (grammar.dashInIdentifiers && c == 45)
    }
}
