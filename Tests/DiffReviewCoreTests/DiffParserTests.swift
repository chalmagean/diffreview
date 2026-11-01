import Testing
@testable import DiffReviewCore

@Suite("DiffParser")
struct DiffParserTests {
    @Test("modified file with multiple hunks gets correct line numbers")
    func multipleHunks() throws {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,4 +1,5 @@ import Foundation
         line1
        -line2
        +line2 changed
        +line2b
         line3
         line4
        @@ -20,3 +21,2 @@ func later() {
         a
        -b
         c

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.oldPath == "Sources/App.swift")
        #expect(file.newPath == "Sources/App.swift")
        #expect(file.status == .modified)
        #expect(file.isBinary == false)
        #expect(file.hunks.count == 2)
        #expect(file.additions == 2)
        #expect(file.deletions == 2)

        let h1 = file.hunks[0]
        #expect(h1.oldStart == 1 && h1.oldCount == 4 && h1.newStart == 1 && h1.newCount == 5)
        #expect(h1.section == "import Foundation")
        #expect(h1.lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context, .context])
        #expect(h1.lines[0].oldNumber == 1 && h1.lines[0].newNumber == 1)
        #expect(h1.lines[1].oldNumber == 2 && h1.lines[1].newNumber == nil)
        #expect(h1.lines[2].oldNumber == nil && h1.lines[2].newNumber == 2)
        #expect(h1.lines[3].newNumber == 3)
        #expect(h1.lines[4].oldNumber == 3 && h1.lines[4].newNumber == 4)
        #expect(h1.lines[2].text == "line2 changed")

        let h2 = file.hunks[1]
        #expect(h2.oldStart == 20 && h2.newStart == 21)
        #expect(h2.lines.map(\.text) == ["a", "b", "c"])
        #expect(h2.lines[2].oldNumber == 22 && h2.lines[2].newNumber == 22)
    }

    @Test("new file")
    func newFile() throws {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.status == .added)
        #expect(file.oldPath == nil)
        #expect(file.newPath == "new.txt")
        #expect(file.newMode == "100644")
        #expect(file.additions == 2)
        #expect(file.hunks[0].lines.map(\.newNumber) == [1, 2])
    }

    @Test("deleted file")
    func deletedFile() throws {
        let diff = """
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index e69de29..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.status == .deleted)
        #expect(file.oldPath == "old.txt")
        #expect(file.newPath == nil)
        #expect(file.path == "old.txt")
        #expect(file.hunks[0].oldCount == 1)
        #expect(file.hunks[0].lines[0].oldNumber == 1)
        #expect(file.deletions == 1)
    }

    @Test("pure rename without content change")
    func pureRename() throws {
        let diff = """
        diff --git a/a/old name.txt b/b/new name.txt
        similarity index 100%
        rename from a/old name.txt
        rename to b/new name.txt

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.status == .renamed)
        #expect(file.oldPath == "a/old name.txt")
        #expect(file.newPath == "b/new name.txt")
        #expect(file.similarity == 100)
        #expect(file.hunks.isEmpty)
        #expect(file.displayPath == "a/old name.txt → b/new name.txt")
    }

    @Test("rename with edits followed by another file")
    func renameWithEdits() throws {
        let diff = """
        diff --git a/lib/x.rb b/lib/y.rb
        similarity index 90%
        rename from lib/x.rb
        rename to lib/y.rb
        index 1111111..2222222 100644
        --- a/lib/x.rb
        +++ b/lib/y.rb
        @@ -1,2 +1,2 @@
        -class X
        +class Y
         end
        diff --git a/README.md b/README.md
        index 3333333..4444444 100644
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -old
        +new

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].status == .renamed)
        #expect(files[0].oldPath == "lib/x.rb")
        #expect(files[0].newPath == "lib/y.rb")
        #expect(files[0].similarity == 90)
        #expect(files[0].hunks.count == 1)
        #expect(files[1].path == "README.md")
        #expect(files[1].status == .modified)
    }

    @Test("copied file")
    func copied() throws {
        let diff = """
        diff --git a/a.txt b/b.txt
        similarity index 100%
        copy from a.txt
        copy to b.txt

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.status == .copied)
        #expect(file.oldPath == "a.txt")
        #expect(file.newPath == "b.txt")
    }

    @Test("binary files")
    func binary() throws {
        let diff = """
        diff --git a/img.png b/img.png
        new file mode 100644
        index 0000000..abcdef0
        Binary files /dev/null and b/img.png differ
        diff --git a/data.bin b/data.bin
        index 1111111..2222222 100644
        Binary files a/data.bin and b/data.bin differ
        diff --git a/gone.bin b/gone.bin
        deleted file mode 100644
        index 1111111..0000000
        Binary files a/gone.bin and /dev/null differ

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.isBinary })
        #expect(files[0].status == .added)
        #expect(files[0].oldPath == nil)
        #expect(files[0].newPath == "img.png")
        #expect(files[1].status == .modified)
        #expect(files[1].path == "data.bin")
        #expect(files[2].status == .deleted)
        #expect(files[2].newPath == nil)
        #expect(files.allSatisfy { $0.hunks.isEmpty })
    }

    @Test("GIT binary patch is treated as binary and its payload skipped")
    func gitBinaryPatch() throws {
        let diff = """
        diff --git a/x.bin b/x.bin
        index 1111111..2222222 100644
        GIT binary patch
        literal 5
        McmZQzWMXCj0003101

        literal 0
        HcmV?d00001

        diff --git a/y.txt b/y.txt
        index 1111111..2222222 100644
        --- a/y.txt
        +++ b/y.txt
        @@ -1 +1 @@
        -a
        +b

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].isBinary)
        #expect(files[0].hunks.isEmpty)
        #expect(files[1].hunks.count == 1)
    }

    @Test("no newline at end of file markers")
    func noNewline() throws {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file

        """
        let file = try #require(DiffParser.parse(diff).first)
        let lines = file.hunks[0].lines
        #expect(lines.count == 3)
        #expect(lines[0].noNewlineAtEnd == false)
        #expect(lines[1].kind == .deletion && lines[1].noNewlineAtEnd)
        #expect(lines[2].kind == .addition && lines[2].noNewlineAtEnd)
    }

    @Test("removed lines that look like file headers stay inside the hunk")
    func headerLookalikes() throws {
        let diff = """
        diff --git a/notes.md b/notes.md
        index 1111111..2222222 100644
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1,2 @@
        --- a/fake
        +++ b/fake
         ok

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.path == "notes.md")
        let lines = file.hunks[0].lines
        #expect(lines.map(\.kind) == [.deletion, .addition, .context])
        #expect(lines[0].text == "-- a/fake")
        #expect(lines[1].text == "++ b/fake")
    }

    @Test("blank context line with stripped leading space")
    func blankContext() throws {
        let diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n"
        let lines = try #require(DiffParser.parse(diff).first).hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .context, .deletion, .addition])
        #expect(lines[1].text == "")
        #expect(lines[1].newNumber == 2)
    }

    @Test("quoted paths are unquoted")
    func quotedPaths() throws {
        let diff = """
        diff --git "a/we\\"ird\\tname.txt" "b/we\\"ird\\tname.txt"
        new file mode 100644
        --- /dev/null
        +++ "b/we\\"ird\\tname.txt"
        @@ -0,0 +1 @@
        +x
        diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
        index 1111111..2222222 100644
        --- "a/caf\\303\\251.txt"
        +++ "b/caf\\303\\251.txt"
        @@ -1 +1 @@
        -a
        +b

        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].newPath == "we\"ird\tname.txt")
        #expect(files[1].path == "café.txt")
    }

    @Test("mode change only")
    func modeChange() throws {
        let diff = """
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.status == .modified)
        #expect(file.oldMode == "100644")
        #expect(file.newMode == "100755")
        #expect(file.path == "run.sh")
        #expect(file.hunks.isEmpty)
    }

    @Test("CRLF content is preserved and paths with spaces parse from header")
    func crlfAndSpaces() throws {
        let diff = "diff --git a/my file.txt b/my file.txt\nindex 1..2 100644\n--- a/my file.txt\n+++ b/my file.txt\n@@ -1 +1 @@\n-a\r\n+b\r\n"
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.path == "my file.txt")
        #expect(file.hunks[0].lines.map(\.text) == ["a\r", "b\r"])
    }

    @Test("empty input yields no files")
    func empty() {
        #expect(DiffParser.parse("").isEmpty)
    }

    @Test("allLines flattens hunks in order")
    func allLines() throws {
        let diff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n@@ -9 +9 @@\n-c\n+d\n"
        let file = try #require(DiffParser.parse(diff).first)
        #expect(file.allLines.map(\.text) == ["a", "b", "c", "d"])
    }
}
