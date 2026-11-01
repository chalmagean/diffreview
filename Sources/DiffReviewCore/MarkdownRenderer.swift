import Foundation

public enum MarkdownRenderer {
    /// Renders the review grouped by file, in diff order. Comments on files that are no longer in the
    /// diff are still included (after the others) so no feedback is silently dropped.
    public static func render(draft: ReviewDraft, files: [FileDiff]) -> String {
        var out = "# Code Review\n\n"
        let summary = trimmed(draft.summary)
        if !summary.isEmpty { out += summary + "\n\n" }

        let comments = draft.comments.filter { !trimmed($0.body).isEmpty }
        let byPath = Dictionary(grouping: comments, by: \.path)
        let knownPaths = files.map(\.path)
        let stalePaths = byPath.keys.filter { !knownPaths.contains($0) }.sorted()
        let filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        var sections: [String] = []
        for path in knownPaths + stalePaths {
            guard let fileComments = byPath[path], !fileComments.isEmpty else { continue }
            var section = "## \(heading(path: path, file: filesByPath[path]))\n\n"
            let ordered = fileComments.sorted(by: order)
            section += ordered.map(renderComment).joined(separator: "\n")
            sections.append(section)
        }

        if sections.isEmpty {
            out += summary.isEmpty ? "No comments.\n" : ""
            return summary.isEmpty ? out : String(out.dropLast())
        }
        out += sections.joined(separator: "\n")
        return out
    }

    static func heading(path: String, file: FileDiff?) -> String {
        guard let file, let old = file.oldPath, old != path else { return path }
        switch file.status {
        case .renamed: return "\(path) (renamed from \(old))"
        case .copied: return "\(path) (copied from \(old))"
        default: return path
        }
    }

    static func order(_ a: ReviewComment, _ b: ReviewComment) -> Bool {
        if a.isFileLevel != b.isFileLevel { return a.isFileLevel }
        let la = a.startLine ?? 0, lb = b.startLine ?? 0
        if la != lb { return la < lb }
        if a.side != b.side { return a.side == .old }
        return a.createdAt < b.createdAt
    }

    static func renderComment(_ c: ReviewComment) -> String {
        let body = trimmed(c.body) + "\n"
        if c.isFileLevel { return body }
        var s = "### \(c.rangeLabel)\n\n"
        if !c.snippet.isEmpty { s += codeBlock(c.snippet, path: c.path) + "\n\n" }
        return s + body
    }

    static func codeBlock(_ lines: [SnippetLine], path: String) -> String {
        let kinds = Set(lines.map(\.kind))
        let asDiff = kinds.contains(.addition) && kinds.contains(.deletion)
        let texts = lines.map { line -> String in
            var t = line.text
            if t.hasSuffix("\r") { t.removeLast() }
            guard asDiff else { return t }
            switch line.kind {
            case .addition: return "+" + t
            case .deletion: return "-" + t
            case .context: return " " + t
            }
        }
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(texts) + 1))
        let lang = asDiff ? "diff" : Language.fenceName(forPath: path)
        return fence + lang + "\n" + texts.joined(separator: "\n") + "\n" + fence
    }

    static func longestBacktickRun(_ lines: [String]) -> Int {
        var best = 0
        for line in lines {
            var run = 0
            for ch in line {
                if ch == "`" { run += 1; best = max(best, run) } else { run = 0 }
            }
        }
        return best
    }

    static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
