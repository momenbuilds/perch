#!/usr/bin/env bash
# Builds Perch.app — a background (menu-bar) app with no Dock icon.
#
#   ./build_app.sh              universal (Intel + Apple Silicon), release
#   ./build_app.sh --native     only this machine's architecture, much faster
#   ./build_app.sh --install    build, then install into /Applications
set -eo pipefail

cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --native)  ARCHS=() ;;
        --install) INSTALL=1 ;;
        debug|release) ;;                     # accepted for backwards compatibility
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="build/Perch.app"

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Perch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Perch</string>
    <key>CFBundleDisplayName</key><string>Perch</string>
    <key>CFBundleIdentifier</key><string>io.github.momenbuilds.perch</string>
    <key>CFBundleExecutable</key><string>Perch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
lipo -archs "$APP/Contents/MacOS/Perch" | sed 's/^/  architectures: /'

if [ "$INSTALL" -eq 1 ]; then
    pkill -x Perch 2>/dev/null || true
    rm -rf /Applications/Perch.app
    cp -R "$APP" /Applications/Perch.app
    open /Applications/Perch.app
    echo "Installed to /Applications/Perch.app and launched."
fi
