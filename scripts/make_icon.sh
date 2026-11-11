#!/bin/bash
# Redraws the app icon (Sources/NotionBar/Dev/AppIcon.swift) into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build 2>&1 | grep -v "search path" || true
rm -rf build/icon
.build/debug/NotionBar --make-icon build/icon
iconutil -c icns build/icon/AppIcon.iconset -o Sources/NotionBar/Resources/AppIcon.icns
echo "wrote Sources/NotionBar/Resources/AppIcon.icns"
