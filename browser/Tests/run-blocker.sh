#!/bin/sh
# Downloads the real filter lists and tests the ad blocker with the real WebKit engine.
# Needs an internet connection.
set -e
cd "$(dirname "$0")/.."
if [ -d /Library/Developer/CommandLineTools ] && ! xcrun swiftc --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
mkdir -p build/filters
curl -fsSL -o build/filters/easylist.txt https://easylist.to/easylist/easylist.txt
curl -fsSL -o build/filters/easyprivacy.txt https://easylist.to/easylist/easyprivacy.txt
curl -fsSL -o build/filters/easylistgermany.txt https://easylist.to/easylistgermany/easylistgermany.txt
xcrun swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" Sources/FilterConverter.swift Tests/Blocker/main.swift -o build/rook-blocker-test
./build/rook-blocker-test build/filters
