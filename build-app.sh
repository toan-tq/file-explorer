#!/bin/bash
#
# build-app.sh — Build FileExplorer Swift app and package as macOS .app bundle
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/FileExplorer.app"
CONTENTS="$APP/Contents"

# ── 1. Build ──────────────────────────────────────────────────────────────────

echo "Building FileExplorer..."
cd "$ROOT"
swift build -c release 2>&1

# ── 2. Create .app bundle ────────────────────────────────────────────────────

echo ""
echo "Packaging FileExplorer.app..."

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

# Copy binary
cp ".build/release/FileExplorer" "$CONTENTS/MacOS/FileExplorer"

# Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>File Explorer</string>
    <key>CFBundleDisplayName</key>
    <string>File Explorer</string>
    <key>CFBundleIdentifier</key>
    <string>com.fileexplorer.app</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>FileExplorer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Convert PNG → ICNS (if icon exists)
if [ -f "$ROOT/resources/app-icon.png" ]; then
    ICONSET="$DIST/FileExplorer.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ROOT/resources/app-icon.png" \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
        double=$((size * 2))
        sips -z $double $double "$ROOT/resources/app-icon.png" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

# ── 3. Done ──────────────────────────────────────────────────────────────────

APP_SIZE=$(du -sh "$APP" | cut -f1)
echo "  Created $APP ($APP_SIZE)"
echo ""
echo "To install:"
echo "  cp -R $APP /Applications/"
echo ""
echo "To test:"
echo "  open $APP"
