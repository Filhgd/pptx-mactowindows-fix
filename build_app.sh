#!/usr/bin/env bash
# Build "PPTX MacToWindows Fix.app" (macOS 13 or newer, Apple silicon + Intel).
# Usage: ./build_app.sh            Result: dist/PPTX MacToWindows Fix.app
#
# Code signing (optional, recommended):
#   CODESIGN_IDENTITY  "Developer ID Application: Name (TEAMID)"
#                      Without it the app is signed ad-hoc.
# Notarization (optional, needs CODESIGN_IDENTITY and NOTARIZE=1):
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (app-specific password)
set -euo pipefail
cd "$(dirname "$0")"

NAME="PPTX MacToWindows Fix"
EXE=PPTXFix
BUNDLE_ID=be.haegdorens.pptxmactowindowsfix
VERSION=$(tr -d '[:space:]' < VERSION)
APP="dist/$NAME.app"
IDENTITY=${CODESIGN_IDENTITY:-}

rm -rf build dist
mkdir -p build dist

# Compile for both architectures and combine.
SDK=$(xcrun --sdk macosx --show-sdk-path)
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macos13.0" \
    -module-name PPTXFix Sources/*.swift -o "build/$EXE-$ARCH"
done
lipo -create -output "build/$EXE" "build/$EXE-arm64" "build/$EXE-x86_64"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$EXE" "$APP/Contents/MacOS/$EXE"

# App icon: assets/icon.png -> AppIcon.icns
mkdir -p build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s * 2))
  sips -z $d $d assets/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

YEAR=$(date +%Y)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© $YEAR Filip Haegdorens</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PowerPoint-presentatie</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>org.openxmlformats.presentationml.presentation</string>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "Signed with: $IDENTITY"

  if [ "${NOTARIZE:-0}" = "1" ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    echo "Notarizing (this takes a few minutes)..."
    ditto -c -k --keepParent "$APP" build/notarize.zip
    xcrun notarytool submit build/notarize.zip \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
    echo "Notarized and stapled."
  fi
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (set CODESIGN_IDENTITY for a Developer ID signature)."
fi

echo
echo "Done: $APP (version $VERSION)"
