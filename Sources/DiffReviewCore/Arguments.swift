import Foundation

public struct ArgumentError: Error, CustomStringConvertible, Equatable {
    public var description: String
}

public struct Arguments: Equatable, Sendable {
    public var mode: DiffMode
    public var help: Bool
    /// The Claude Code session that opened the review: chats fork it, so they answer
    /// with what that session knows about the code.
    public var session: String?

    public init(mode: DiffMode = .uncommitted, help: Bool = false, session: String? = nil) {
        self.mode = mode
        self.help = help
        self.session = session
    }

    public static let usage = """
    Usage: diffreview [--base <ref> | <commit> | <commit>..<commit> | <commit>...<commit>] [--session <id>]

    Opens a window to review changes. On "Submit review" the review is printed to
    stdout as markdown (exit 0). Closing without submitting prints nothing (exit 1).

      (no options)    uncommitted changes: git diff HEAD plus untracked files
      --base <ref>    commits on the current branch since its merge-base with <ref>
      <commit>        the changes made by that one commit (like git show)
      A..B            committed changes from A to B (git diff A B)
      A...B           changes on B since it forked from A (git diff A...B)
                      In a range, an empty side means HEAD: "abc123.." is abc123..HEAD.
      --session <id>  the Claude Code session that opened the review: "Ask Claude"
                      chats start as forks of it (default: $CLAUDE_CODE_SESSION_ID)
      -h, --help      show this help

    Drafts are autosaved to .git/diffreview/comments.json and cleared on submit.
    """

    public static func parse(_ args: [String]) throws -> Arguments {
        var result = Arguments()
        var commits: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                result.help = true
            case "--base":
                guard i + 1 < args.count, !args[i + 1].isEmpty else {
                    throw ArgumentError(description: "--base requires a ref")
                }
                result.mode = .base(args[i + 1])
                i += 1
            case "--session":
                guard i + 1 < args.count else { throw ArgumentError(description: "--session requires an id") }
                // Empty when the command's placeholder wasn't filled in: just no session.
                result.session = args[i + 1].isEmpty ? nil : args[i + 1]
                i += 1
            default:
                if arg.hasPrefix("--base=") {
                    let ref = String(arg.dropFirst("--base=".count))
                    guard !ref.isEmpty else { throw ArgumentError(description: "--base requires a ref") }
                    result.mode = .base(ref)
                } else if arg.hasPrefix("--session=") {
                    let id = String(arg.dropFirst("--session=".count))
                    result.session = id.isEmpty ? nil : id
                } else if arg.hasPrefix("-") || arg.isEmpty {
                    throw ArgumentError(description: "Unknown argument '\(arg)'")
                } else {
                    guard commits == nil else {
                        throw ArgumentError(description: "Only one commit or range can be reviewed at a time")
                    }
                    commits = arg
                }
            }
            i += 1
        }
        if let commits {
            guard result.mode == .uncommitted else {
                throw ArgumentError(description: "--base can't be combined with a commit or range")
            }
            result.mode = .commits(commits)
        }
        return result
    }
}
