import Foundation

/// Maps file paths to language identifiers. Used for markdown code fences, and is the hook the UI's
/// syntax highlighter keys off.
public enum Language {
    static let byExtension: [String: String] = [
        "swift": "swift", "rb": "ruby", "rake": "ruby", "gemspec": "ruby", "erb": "erb",
        "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "jsx",
        "ts": "typescript", "tsx": "tsx", "go": "go", "rs": "rust", "c": "c", "h": "c",
        "cc": "cpp", "cpp": "cpp", "hpp": "cpp", "m": "objectivec", "mm": "objectivec",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "cs": "csharp", "php": "php",
        "sh": "bash", "bash": "bash", "zsh": "zsh", "fish": "fish", "json": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "xml": "xml", "plist": "xml",
        "html": "html", "htm": "html", "css": "css", "scss": "scss", "sass": "sass",
        "md": "markdown", "markdown": "markdown", "sql": "sql", "ex": "elixir", "exs": "elixir",
        "erl": "erlang", "hs": "haskell", "lua": "lua", "r": "r", "scala": "scala",
        "dart": "dart", "vue": "vue", "svelte": "svelte", "tf": "hcl", "proto": "protobuf",
        "graphql": "graphql", "gql": "graphql", "dockerfile": "dockerfile", "zig": "zig",
        "clj": "clojure", "ml": "ocaml", "pl": "perl", "groovy": "groovy", "gradle": "groovy",
    ]

    static let byFilename: [String: String] = [
        "Makefile": "makefile", "GNUmakefile": "makefile", "Dockerfile": "dockerfile",
        "Gemfile": "ruby", "Rakefile": "ruby", "Podfile": "ruby", "Brewfile": "ruby",
        "Guardfile": "ruby", "Vagrantfile": "ruby", "Package.swift": "swift",
    ]

    /// Language name for a markdown fence, or "" if unknown.
    public static func fenceName(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if let lang = byFilename[name] { return lang }
        let ext = (name as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? ""
    }
}
