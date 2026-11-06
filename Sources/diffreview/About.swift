import AppKit

/// What the About panel shows. A bare SwiftPM executable has no Info.plist, so the
/// standard panel can't find any of this on its own.
enum AppInfo {
    static let name = "diffreview"
    /// Bump when cutting a release.
    static let version = "0.1.0"
    static let author = "Cezar Halmagean"
    static let repository = URL(string: "https://github.com/chalmagean/diffreview")!
    static let license = "MIT License"
    static let copyrightYear = "2026"

    /// When the running binary was built (its modification time), so a stale build is obvious.
    static var buildDate: Date? {
        let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: name,
            .applicationVersion: version,
            .credits: credits(),
        ]
        if let buildDate {
            // Shown in parentheses after the version: "Version 0.1.0 (Built …)".
            options[.version] = "Built " + buildDate.formatted(date: .abbreviated, time: .shortened)
        }
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: "Review git diffs GitHub-style.\n\n", attributes: base)
        var link = base
        link[.link] = repository
        text.append(NSAttributedString(string: repository.absoluteString.replacingOccurrences(of: "https://", with: ""),
                                       attributes: link))
        text.append(NSAttributedString(string: "\n\n© \(copyrightYear) \(author) · \(license)", attributes: base))
        return text
    }
}
