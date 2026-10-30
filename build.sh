#!/bin/bash
# Builds build/Fireplace.app with the Command Line Tools (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Fireplace.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Fireplace"

cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature so macOS can remember the microphone permission.
codesign --force --sign - "$APP"

echo "Built $APP — launch it with: open $APP"
