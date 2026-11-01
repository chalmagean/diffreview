import SwiftUI

/// Hook for syntax highlighting. `language` comes from `Language.fenceName(forPath:)` ("" if unknown).
/// Implementations must be cheap per call (they run for every visible row) or cache internally.
protocol SyntaxHighlighter {
    func highlight(_ code: String, language: String) -> AttributedString
}

struct PlainHighlighter: SyntaxHighlighter {
    func highlight(_ code: String, language: String) -> AttributedString {
        AttributedString(code)
    }
}
