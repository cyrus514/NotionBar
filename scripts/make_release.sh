#!/bin/bash
# Builds the app for Apple silicon and Intel, and zips it for a GitHub release.
#
#   scripts/make_release.sh        → build/NotionBar-<version>.zip
#
# The app is signed for local use only ("ad hoc"), not notarized: people who download it
# have to allow it once under System Settings → Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
APP="build/NotionBar.app"
ZIP="build/NotionBar-$VERSION.zip"

# Each processor gets its own build folder, so one build can't overwrite the other.
echo "› compiling for Apple silicon…"
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 2>&1 | grep -E "error" || true
echo "› compiling for Intel…"
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 2>&1 | grep -E "error" || true
ARM="$(swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --show-bin-path)/NotionBar"
INTEL="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --show-bin-path)/NotionBar"

./build.sh >/dev/null                      # assembles build/NotionBar.app (Info.plist, resources, icon)
lipo -create "$ARM" "$INTEL" -output "$APP/Contents/MacOS/NotionBar"
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"
echo "  version:  $VERSION"
echo "  runs on:  $(lipo -archs "$APP/Contents/MacOS/NotionBar")"
echo "  size:     $(du -h "$ZIP" | cut -f1 | tr -d ' ')"
echo "  sha256:   $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
