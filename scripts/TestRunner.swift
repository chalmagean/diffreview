// Minimal swift-testing runner used by scripts/test.sh when only the Command Line Tools
// are active. It loads the test bundle built by `swift build --build-tests` and hands
// control to swift-testing's SwiftPM entry point (the same one `swift test` uses).
import Foundation
import Testing

@main struct Runner {
    static func main() async {
        guard CommandLine.arguments.count > 1 else {
            FileHandle.standardError.write(Data("usage: swift-testing-runner <test-bundle-binary>\n".utf8))
            exit(2)
        }
        let bundle = CommandLine.arguments[1]
        guard dlopen(bundle, RTLD_NOW) != nil else {
            FileHandle.standardError.write(Data("could not load \(bundle): \(String(cString: dlerror()))\n".utf8))
            exit(2)
        }
        let code: CInt = await Testing.__swiftPMEntryPoint(passing: nil)
        exit(code)
    }
}
