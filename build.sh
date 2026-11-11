#!/bin/bash
# Builds build/NotionBar.app. Needs only the Xcode Command Line Tools (no Xcode).
#
#   ./build.sh             build the app
#   ./build.sh --run       build, then launch it
#   ./build.sh --demo      build, then launch it on sample data (no Notion token needed)
#   ./build.sh --install   build, copy it to /Applications, then launch it from there
set -euo pipefail
cd "$(dirname "$0")"

APP="build/NotionBar.app"
RESOURCES="Sources/NotionBar/Resources"

echo "› compiling (release)…"
swift build -c release 2>&1 | grep -v "search path" || true
BIN="$(swift build -c release --show-bin-path)/NotionBar"
[ -x "$BIN" ] || { echo "build failed: run 'swift build -c release' to see why"; exit 1; }

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotionBar"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$RESOURCES"/*.json "$APP/Contents/Resources/"
[ -f "$RESOURCES/AppIcon.icns" ] && cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/"

# Sign it for this Mac only ("ad hoc"). macOS won't run an unsigned app on Apple silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"
echo "✓ built $APP"

# Stops any copy that's running, so the new build is the one that starts.
# (Asking it to quit through AppleScript needs an Automation permission; a plain signal doesn't.)
quit_running() {
    pkill -f "NotionBar.app/Contents/MacOS/NotionBar" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "NotionBar.app/Contents/MacOS/NotionBar" >/dev/null 2>&1 || return 0
        sleep 0.3
    done
    echo "couldn't stop the running NotionBar: quit it from its menu bar icon, then run this again"
    exit 1
}

case "${1:-}" in
    --run)
        quit_running
        open "$APP"
        ;;
    --demo)
        quit_running
        open -n "$APP" --args --demo --show
        ;;
    --install)
        quit_running
        rm -rf "/Applications/NotionBar.app"
        cp -R "$APP" "/Applications/NotionBar.app"
        echo "✓ installed /Applications/NotionBar.app"
        open "/Applications/NotionBar.app"
        ;;
    "")
        echo "  drag it into /Applications, or run: ./build.sh --install"
        ;;
    *)
        echo "unknown option: $1"; exit 1
        ;;
esac
