#!/bin/bash
# Packs build/NotionBar.app into an installer disk image: a window holding the app and a shortcut to
# Applications, on a picture of the install steps written as one of NotionBar's own task lists.
#
#   scripts/make_dmg.sh        → build/NotionBar-<version>.dmg
#
# It packs whatever app is in build/. Run scripts/make_release.sh instead to build for both
# processors first and get the .zip and the .dmg together.
#
# Finder arranges the window, so the first run may ask to let your terminal control Finder, and a
# Finder window opens for a moment while it works.
#
# The picture comes from Support/dmg/ (redraw it with scripts/dmg_background.swift). The icon
# positions below have to match `Layout` in that file.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
APP="build/NotionBar.app"
DMG="build/NotionBar-$VERSION.dmg"
VOLUME="NotionBar"
# Finder writes the path of the image it arranged into the saved layout, so build it somewhere
# neutral rather than under a home folder: the layout ships inside the download.
WORK="$(mktemp -d /tmp/notionbar-dmg.XXXXXX)"

WINDOW_WIDTH=660; WINDOW_HEIGHT=400; TITLE_BAR=28
ICON_SIZE=128
APP_X=202; APP_Y=200
APPLICATIONS_X=502; APPLICATIONS_Y=200

[ -d "$APP" ] || ./build.sh >/dev/null
codesign --verify --strict "$APP"

if [ -e "/Volumes/$VOLUME" ]; then
    echo "✗ a disk called $VOLUME is already open. Eject it and run this again."
    exit 1
fi

MOUNT=""
cleanup() {
    [ -n "$MOUNT" ] && [ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# 1. What goes on the disk.
rm -f "$DMG"
mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/NotionBar.app"
ln -s /Applications "$WORK/stage/Applications"
tiffutil -cathidpicheck Support/dmg/background.png Support/dmg/background@2x.png \
    -out "$WORK/stage/.background/background.tiff" >/dev/null 2>&1

# 2. A writable disk image, with room for Finder to save the window layout.
echo "› making the disk image…"
SIZE_MB=$(( $(du -sm "$WORK/stage" | cut -f1) + 20 ))
hdiutil create -quiet -ov -srcfolder "$WORK/stage" -volname "$VOLUME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" "$WORK/rw.dmg"
# (stderr is dropped because newer macOS prints a notice that it prefers `diskutil image attach`.)
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" 2>/dev/null | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | head -1)"
[ -d "$MOUNT" ] || { echo "✗ couldn't open the disk image"; exit 1; }

# 3. Finder lays out the window and saves that on the disk (in .DS_Store).
echo "› arranging the window…"
LEFT=200; TOP=140
if ! osascript >/dev/null <<EOF
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        try
            set pathbar visible of container window to false
        end try
        set the bounds of container window to {$LEFT, $TOP, $((LEFT + WINDOW_WIDTH)), $((TOP + WINDOW_HEIGHT + TITLE_BAR))}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to $ICON_SIZE
        set text size of options to 12
        set label position of options to bottom
        set shows item info of options to false
        set background picture of options to file ".background:background.tiff"
        set position of item "NotionBar.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$APPLICATIONS_X, $APPLICATIONS_Y}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "✗ Finder wouldn't arrange the window. Allow your terminal to control Finder under"
    echo "  System Settings → Privacy & Security → Automation, then run this again."
    exit 1
fi

# Finder writes the layout a moment after the window closes.
for _ in $(seq 1 20); do
    [ -s "$MOUNT/.DS_Store" ] && break
    sleep 0.5
done
[ -s "$MOUNT/.DS_Store" ] || { echo "✗ Finder didn't save the window layout"; exit 1; }

# 4. The disk's own icon. This has to come after Finder is done: its "update" throws a custom
#    disk icon away.
cp Sources/NotionBar/Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -c icnC "$MOUNT/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "$MOUNT" 2>/dev/null || true                 # "this disk has a custom icon"

# 5. Tidy up and lock everything down.
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
bless --folder "$MOUNT" --openfolder "$MOUNT" 2>/dev/null || true   # open the window when the disk is opened
sync

for _ in 1 2 3 4 5; do
    hdiutil detach "$MOUNT" -quiet 2>/dev/null && break
    sleep 1
done
[ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force
MOUNT=""

# 6. Compress it into the read-only image people download.
hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$DMG"
hdiutil verify -quiet "$DMG"

echo "✓ $DMG"
echo "  version:  $VERSION"
echo "  runs on:  $(lipo -archs "$APP/Contents/MacOS/NotionBar")"
echo "  size:     $(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "  sha256:   $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
