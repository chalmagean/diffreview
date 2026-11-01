// swift-tools-version:6.0
import Foundation
import PackageDescription

// With only the Command Line Tools active (no Xcode), SwiftPM doesn't put the swift-testing
// framework on the search paths, so the test target adds them itself. Under Xcode nothing changes.
let cltRoot = "/Library/Developer/CommandLineTools"
let cltFrameworks = cltRoot + "/Library/Developer/Frameworks"
let cltLibs = cltRoot + "/Library/Developer/usr/lib"

/// Mirrors `xcode-select -p`: DEVELOPER_DIR, then the xcode-select choice, then the default.
func activeDeveloperDir() -> String {
    if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty { return dir }
    if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
        return link
    }
    return FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        ? "/Applications/Xcode.app/Contents/Developer" : cltRoot
}

let usingCLT = activeDeveloperDir().hasPrefix(cltRoot)
    && FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")

let package = Package(
    name: "diffreview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "diffreview", targets: ["diffreview"]),
        .library(name: "DiffReviewCore", targets: ["DiffReviewCore"]),
    ],
    targets: [
        .target(name: "DiffReviewCore"),
        .executableTarget(name: "diffreview", dependencies: ["DiffReviewCore"]),
        .testTarget(
            name: "DiffReviewCoreTests",
            dependencies: ["DiffReviewCore"],
            swiftSettings: usingCLT ? [.unsafeFlags(["-F", cltFrameworks])] : [],
            linkerSettings: usingCLT
                ? [.unsafeFlags(["-F", cltFrameworks,
                                 "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                                 "-Xlinker", "-rpath", "-Xlinker", cltLibs])]
                : []
        ),
    ],
    swiftLanguageModes: [.v5]
)
