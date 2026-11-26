import Testing
@testable import DiffReviewCore

@Suite("DiffTableLayout")
struct DiffTableLayoutTests {
    @Test func eachFileIsItsHeaderThenItsTopRowThenItsRows() {
        let layout = DiffTableLayout(rowCounts: [2, 1], collapsed: [])
        #expect(layout.rows == [
            .fileHeader(file: 0), .fileTop(file: 0), .row(file: 0, index: 0), .row(file: 0, index: 1),
            .fileHeader(file: 1), .fileTop(file: 1), .row(file: 1, index: 0),
        ])
    }

    @Test func aCollapsedFileKeepsOnlyItsHeaderAndTopRow() {
        let layout = DiffTableLayout(rowCounts: [2, 3], collapsed: [0])
        #expect(layout.rows == [
            .fileHeader(file: 0), .fileTop(file: 0),
            .fileHeader(file: 1), .fileTop(file: 1),
            .row(file: 1, index: 0), .row(file: 1, index: 1), .row(file: 1, index: 2),
        ])
    }

    @Test func aFileWithoutRowsStillHasItsHeaderAndTopRow() {
        let layout = DiffTableLayout(rowCounts: [0], collapsed: [])
        #expect(layout.rows == [.fileHeader(file: 0), .fileTop(file: 0)])
    }

    @Test func findsTheTableRowOfAnyEntry() {
        let layout = DiffTableLayout(rowCounts: [2, 3], collapsed: [0])
        for (i, row) in layout.rows.enumerated() {
            #expect(layout.index(of: row) == i)
        }
        #expect(layout.headerRow(ofFile: 1) == 2)
    }

    @Test func entriesThatArentShownHaveNoTableRow() {
        let layout = DiffTableLayout(rowCounts: [2, 3], collapsed: [0])
        #expect(layout.index(of: .row(file: 0, index: 0)) == nil) // collapsed
        #expect(layout.index(of: .row(file: 1, index: 3)) == nil) // past the end
        #expect(layout.headerRow(ofFile: 2) == nil)
    }

    @Test func theFileBeingReadIsTheFirstWithCodeOnScreen() {
        // Files 0–2 collapsed: their headers stack up above file 3's code.
        let layout = DiffTableLayout(rowCounts: [2, 2, 2, 3], collapsed: [0, 1, 2])
        let firstHeader = layout.headerRow(ofFile: 1)!
        #expect(layout.fileBeingRead(inRows: firstHeader..<layout.rows.count) == 3)
    }

    @Test func aFileScrolledPartwayIsTheFileBeingRead() {
        let layout = DiffTableLayout(rowCounts: [3, 3], collapsed: [])
        let middleOfFirst = layout.index(of: .row(file: 0, index: 1))!
        #expect(layout.fileBeingRead(inRows: middleOfFirst..<layout.rows.count) == 0)
    }

    @Test func withNoCodeOnScreenTheTopFileIsTheFileBeingRead() {
        let layout = DiffTableLayout(rowCounts: [2, 2, 2], collapsed: [0, 1, 2])
        #expect(layout.fileBeingRead(inRows: 2..<layout.rows.count) == 1)
        #expect(layout.fileBeingRead(inRows: 0..<0) == nil)
    }

    @Test func everyEntryKnowsItsFile() {
        #expect(DiffTableRow.fileHeader(file: 3).file == 3)
        #expect(DiffTableRow.fileTop(file: 4).file == 4)
        #expect(DiffTableRow.row(file: 5, index: 9).file == 5)
    }
}

@Suite("CodeColumns")
struct CodeColumnsTests {
    @Test func plainTextIsOneColumnPerCharacter() {
        #expect(CodeColumns.width(of: "") == 0)
        #expect(CodeColumns.width(of: "let x = 1") == 9)
    }

    @Test func tabsAdvanceToTheNextTabStop() {
        #expect(CodeColumns.width(of: "\tx") == 5)
        #expect(CodeColumns.width(of: "ab\tx") == 5)
        #expect(CodeColumns.width(of: "abcd\tx") == 9)
        #expect(CodeColumns.width(of: "\t\t") == 8)
    }

    @Test func textWhoseWidthDependsOnTheFontIsUnknown() {
        #expect(CodeColumns.width(of: "naïve") == nil)
        #expect(CodeColumns.width(of: "日本") == nil)
        #expect(CodeColumns.width(of: "ok 👍") == nil)
        #expect(CodeColumns.width(of: "a\u{7}b") == nil)
    }
}
