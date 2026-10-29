#!/bin/zsh
# Builds build/Launchpad.app (release, Apple Silicon, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
# Use Xcode's toolchain; a swiftly/open-source swift may not match the macOS SDK.
SWIFT=/usr/bin/swift
$SWIFT build -c release --arch arm64
BIN="$($SWIFT build -c release --arch arm64 --show-bin-path)/Launchpad"

APP=build/Launchpad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Launchpad"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  $SWIFT scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"
