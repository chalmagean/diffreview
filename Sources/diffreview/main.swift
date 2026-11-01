import AppKit
import DiffReviewCore

// stdout is reserved for the final review markdown; everything else goes to stderr.
func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("diffreview: \(message)\n".utf8))
    exit(code)
}

let arguments: Arguments
do {
    arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\n\(Arguments.usage)")
}
if arguments.help {
    print(Arguments.usage)
    exit(0)
}

let git: Git
let files: [FileDiff]
do {
    git = try Git(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    files = try git.loadDiff(mode: arguments.mode)
} catch {
    fail("\(error)")
}
if files.isEmpty {
    fail("no changes to review", code: 1)
}

let title: String
switch arguments.mode {
case .uncommitted: title = "Uncommitted changes"
case .base(let ref): title = "Changes since \(ref)"
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let store = ReviewStore(files: files, title: title, repoName: git.root.lastPathComponent,
                            draftStore: DraftStore(gitDir: git.gitDir))
    let delegate = AppDelegate(store: store)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
