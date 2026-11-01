#!/bin/sh
# Runs the test suite.
#
# Under Xcode this is just `swift test`. With only the Command Line Tools active,
# `swift test` builds the swift-testing tests but silently runs none of them (and
# still exits 0), so we build the test bundle and run it through scripts/TestRunner.swift,
# which calls swift-testing's entry point directly.
set -e
cd "$(dirname "$0")/.."

case "$(xcode-select -p 2>/dev/null)" in
  /Library/Developer/CommandLineTools*) ;;
  *) exec swift test "$@" ;;
esac

F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
RUNNER=.build/swift-testing-runner

swift build --build-tests
if [ ! -x "$RUNNER" ] || [ scripts/TestRunner.swift -nt "$RUNNER" ]; then
  swiftc -parse-as-library -F "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" \
    scripts/TestRunner.swift -o "$RUNNER"
fi
BUNDLE="$(swift build --show-bin-path)/diffreviewPackageTests.xctest/Contents/MacOS/diffreviewPackageTests"
exec "$RUNNER" "$BUNDLE" "$@"
