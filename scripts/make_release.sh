#!/bin/bash
# Builds the app for Apple silicon and Intel, and packs it into the installer disk image that goes
# on a GitHub release.
#
#   scripts/make_release.sh        → build/NotionBar-<version>.dmg
#
# The app is signed for local use only ("ad hoc"), not notarized: people who download it
# have to allow it once under System Settings → Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/NotionBar.app"

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

# The window, the picture and the disk icon are scripts/make_dmg.sh's job.
scripts/make_dmg.sh
