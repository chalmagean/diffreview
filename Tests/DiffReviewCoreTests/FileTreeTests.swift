import Testing
@testable import DiffReviewCore

@Suite("FileTree")
struct FileTreeTests {
    typealias Node = FileTreeNode

    @Test("files at the root stay flat")
    func rootFiles() {
        #expect(FileTree.build(paths: ["a.swift", "b.swift"]) == [
            .file(name: "a.swift", path: "a.swift", index: 0),
            .file(name: "b.swift", path: "b.swift", index: 1),
        ])
    }

    @Test("folders holding only one folder are joined into one row, as on GitHub")
    func compressesChains() {
        let tree = FileTree.build(paths: [
            "activerecord/lib/active_record/associations/association.rb",
            "activerecord/test/cases/associations/belongs_test.rb",
        ])
        #expect(tree == [
            .directory(name: "activerecord", path: "activerecord", children: [
                .directory(name: "lib/active_record/associations",
                           path: "activerecord/lib/active_record/associations", children: [
                    .file(name: "association.rb",
                          path: "activerecord/lib/active_record/associations/association.rb", index: 0),
                ]),
                .directory(name: "test/cases/associations",
                           path: "activerecord/test/cases/associations", children: [
                    .file(name: "belongs_test.rb",
                          path: "activerecord/test/cases/associations/belongs_test.rb", index: 1),
                ]),
            ]),
        ])
    }

    @Test("a single deep file gets one joined folder row")
    func singleDeepFile() {
        #expect(FileTree.build(paths: ["Sources/App/main.swift"]) == [
            .directory(name: "Sources/App", path: "Sources/App", children: [
                .file(name: "main.swift", path: "Sources/App/main.swift", index: 0),
            ]),
        ])
    }

    @Test("a folder with both a file and a subfolder is not joined")
    func mixedFolder() {
        #expect(FileTree.build(paths: ["a/one.txt", "a/b/two.txt"]) == [
            .directory(name: "a", path: "a", children: [
                .file(name: "one.txt", path: "a/one.txt", index: 0),
                .directory(name: "b", path: "a/b", children: [
                    .file(name: "two.txt", path: "a/b/two.txt", index: 1),
                ]),
            ]),
        ])
    }

    @Test("entries keep the order they first appear in, matching the diff")
    func keepsDiffOrder() {
        #expect(FileTree.build(paths: ["b/x", "a.txt", "b/y"]) == [
            .directory(name: "b", path: "b", children: [
                .file(name: "x", path: "b/x", index: 0),
                .file(name: "y", path: "b/y", index: 2),
            ]),
            .file(name: "a.txt", path: "a.txt", index: 1),
        ])
    }

    @Test("no paths, no tree")
    func empty() {
        #expect(FileTree.build(paths: []).isEmpty)
    }
}
