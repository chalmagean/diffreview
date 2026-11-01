import Foundation

/// Persists the in-progress review at `<git-dir>/diffreview/comments.json`.
public struct DraftStore: Sendable {
    public let url: URL

    public init(gitDir: URL) {
        url = gitDir.appendingPathComponent("diffreview", isDirectory: true)
            .appendingPathComponent("comments.json")
    }

    public func load() -> ReviewDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(ReviewDraft.self, from: data)
    }

    public func save(_ draft: ReviewDraft) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(draft).write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
        // Remove the directory too if nothing else lives there.
        let dir = url.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
