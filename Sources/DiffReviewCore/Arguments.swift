import Foundation

public struct ArgumentError: Error, CustomStringConvertible, Equatable {
    public var description: String
}

public struct Arguments: Equatable, Sendable {
    public var mode: DiffMode
    public var help: Bool

    public init(mode: DiffMode = .uncommitted, help: Bool = false) {
        self.mode = mode
        self.help = help
    }

    public static let usage = """
    Usage: diffreview [--base <ref>]

    Opens a window to review changes. On "Submit review" the review is printed to
    stdout as markdown (exit 0). Closing without submitting prints nothing (exit 1).

      (no options)    uncommitted changes: git diff HEAD plus untracked files
      --base <ref>    commits on the current branch since its merge-base with <ref>
      -h, --help      show this help

    Drafts are autosaved to .git/diffreview/comments.json and cleared on submit.
    """

    public static func parse(_ args: [String]) throws -> Arguments {
        var result = Arguments()
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
            default:
                if arg.hasPrefix("--base=") {
                    let ref = String(arg.dropFirst("--base=".count))
                    guard !ref.isEmpty else { throw ArgumentError(description: "--base requires a ref") }
                    result.mode = .base(ref)
                } else {
                    throw ArgumentError(description: "Unknown argument '\(arg)'")
                }
            }
            i += 1
        }
        return result
    }
}
