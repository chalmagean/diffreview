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

/// The diff, loaded off the main thread while AppKit starts up: on a big diff, git, parsing and
/// preparing the rows take seconds, and AppKit's own startup takes about one more.
final class DiffLoading: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Loaded, Error>?

    struct Loaded {
        let git: Git
        let files: [DisplayFile]
        /// What's being reviewed, for the top of the output; nil for uncommitted changes.
        let context: String?
    }

    init(mode: DiffMode) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.result = Result {
                let git = try Git(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                let range = try git.commitRange(for: mode)
                let files = ReviewStore.prepare(try git.loadDiff(mode: mode, range: range))
                let context = try range.map { try git.reviewedCommits($0).description }
                return Loaded(git: git, files: files, context: context)
            }
            self.done.signal()
        }
    }

    /// Waits for the diff; exits, without showing anything, when there's none to review.
    func wait() -> Loaded {
        done.wait()
        switch result! {
        case .failure(let error): fail("\(error)")
        case .success(let loaded):
            if loaded.files.isEmpty { fail("no changes to review", code: 1) }
            return loaded
        }
    }
}

let loading = DiffLoading(mode: arguments.mode)

let title: String
switch arguments.mode {
case .uncommitted: title = "Uncommitted changes"
case .base(let ref): title = "Changes since \(ref)"
case .commits(let spec): title = spec.contains("..") ? "Changes in \(spec)" : "Commit \(spec)"
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate {
        let loaded = loading.wait()
        let chats = ChatStore(directory: loaded.git.root, gitDir: loaded.git.gitDir, reviewing: title,
                              sessionArgument: arguments.session)
        return ReviewStore(files: loaded.files, title: title, repoName: loaded.git.root.lastPathComponent,
                           context: loaded.context, draftStore: DraftStore(gitDir: loaded.git.gitDir),
                           chats: chats)
    }
    app.delegate = delegate
    app.run()
}
