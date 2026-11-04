import Foundation
import Testing
@testable import DiffReviewCore

@Suite("InlineDiff")
struct InlineDiffTests {
    @Test("a changed word is marked on both sides")
    func changedWord() throws {
        let result = try #require(InlineDiff.changes(old: "let x = 1", new: "let x = 2"))
        #expect(result.old == [NSRange(location: 8, length: 1)])
        #expect(result.new == [NSRange(location: 8, length: 1)])
    }

    @Test("an insertion marks only the new side, with adjacent tokens merged")
    func insertion() throws {
        let result = try #require(InlineDiff.changes(old: "foo(a)", new: "foo(a, b)"))
        #expect(result.old.isEmpty)
        #expect(result.new == [NSRange(location: 5, length: 3)])
    }

    @Test("whole identifiers are marked, not single characters inside them")
    func wholeWords() throws {
        let oldLine = "sc.execute(owner.method(:read_attr), c, async: async) do |record|"
        let newLine = "sc.execute(->(name) { owner.read_attr(name) }, c, async: async) do |record|"
        let result = try #require(InlineDiff.changes(old: oldLine, new: newLine))
        let old = result.old.map { (oldLine as NSString).substring(with: $0) }
        let new = result.new.map { (newLine as NSString).substring(with: $0) }
        #expect(old.contains { $0.contains("method") })
        #expect(!old.contains { $0.contains("meth") && !$0.contains("method") })
        #expect(new.contains { $0.hasPrefix("->") })
        // The shared tail is untouched.
        #expect(!new.contains { $0.contains("async") || $0.contains("record") })
    }

    @Test("lines with too little in common get no inline marks")
    func tooDifferent() {
        #expect(InlineDiff.changes(old: "return total", new: "print(error.message)") == nil)
    }

    @Test("ranges are UTF-16 offsets, so they line up with the drawn text")
    func utf16Offsets() throws {
        let result = try #require(InlineDiff.changes(old: "a 🙂 b", new: "a 🙂 c"))
        #expect(result.old == [NSRange(location: 5, length: 1)])
        #expect(result.new == [NSRange(location: 5, length: 1)])
    }

    @Test("a trailing carriage return is ignored, as the code view drops it")
    func carriageReturn() throws {
        let result = try #require(InlineDiff.changes(old: "x = 1\r", new: "x = 2\r"))
        #expect(result.old == [NSRange(location: 4, length: 1)])
        #expect(result.new == [NSRange(location: 4, length: 1)])
    }

    @Test("identical lines have nothing to mark")
    func identical() throws {
        let result = try #require(InlineDiff.changes(old: "same", new: "same"))
        #expect(result.old.isEmpty && result.new.isEmpty)
    }

    @Test("deletions pair with the additions that follow them, in order")
    func pairing() {
        let lines = [
            DiffLine(kind: .context, text: "start", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .deletion, text: "let a = 1", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .deletion, text: "let b = 1", oldNumber: 3, newNumber: nil),
            DiffLine(kind: .addition, text: "let a = 2", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .addition, text: "let b = 2", oldNumber: nil, newNumber: 3),
            DiffLine(kind: .addition, text: "let c = 2", oldNumber: nil, newNumber: 4),
            DiffLine(kind: .context, text: "end", oldNumber: 4, newNumber: 5),
        ]
        let marks = InlineDiff.emphasis(for: lines)
        let one = [NSRange(location: 8, length: 1)]
        #expect(marks == [1: one, 2: one, 3: one, 4: one])
    }

    @Test("lone additions and deletions get no marks")
    func unpaired() {
        let lines = [
            DiffLine(kind: .deletion, text: "let a = 1", oldNumber: 1, newNumber: nil),
            DiffLine(kind: .context, text: "middle", oldNumber: 2, newNumber: 1),
            DiffLine(kind: .addition, text: "let a = 2", oldNumber: nil, newNumber: 2),
        ]
        #expect(InlineDiff.emphasis(for: lines).isEmpty)
    }

    @Test("a pure insertion leaves the deleted line without marks")
    func insertionPair() {
        let lines = [
            DiffLine(kind: .deletion, text: "foo(a)", oldNumber: 1, newNumber: nil),
            DiffLine(kind: .addition, text: "foo(a, b)", oldNumber: nil, newNumber: 1),
        ]
        #expect(InlineDiff.emphasis(for: lines) == [1: [NSRange(location: 5, length: 3)]])
    }
}
