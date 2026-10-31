#!/bin/sh
# Compiles Rook's sources (without the app start) together with the tests and runs them.
set -e
cd "$(dirname "$0")/.."
if [ -d /Library/Developer/CommandLineTools ] && ! xcrun swiftc --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
mkdir -p build
SOURCES=$(ls Sources/*.swift | grep -v main.swift)
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" $SOURCES Tests/main.swift -o build/rook-tests
./build/rook-tests
