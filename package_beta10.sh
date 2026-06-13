#!/bin/zsh
set -e

# GONE — package Beta 1.0 into an ad-hoc DMG (no Developer ID).
# Order matters: PlistBuddy (display name + version) BEFORE codesign — Info.plist lives
# inside the signed bundle, so editing it after signing invalidates the signature
# (crash -67030).

APP_NAME="GONE Player Beta 1.0"
SHORT_VERSION="1.0"
BUILD_VERSION="13"
ENTITLEMENTS="$(dirname "$0")/GONE/GONE_release.entitlements"   # intentionally empty (no sandbox)
OUT_DIR="$HOME/Desktop"
DMG_PATH="$OUT_DIR/$APP_NAME.dmg"

# Prefer the explicit headless Release build; fall back to an Xcode (Cmd+B) build in DerivedData.
APP_PATH="/tmp/gone_dd_release/Build/Products/Release/GONE.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "→ Explicit build not found, searching DerivedData..."
  APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "GONE.app" -path "*/Release/*" | head -1)
fi
[[ -d "$APP_PATH" ]] || { echo "✗ Release build not found. Build Release first."; exit 1; }
echo "  App: $APP_PATH"

echo "→ Setting display name + bundle version (PlistBuddy, BEFORE signing)..."
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_PATH/Contents/Info.plist"

echo "→ Signing ad-hoc with entitlements..."
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "→ Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"

echo "✓ Done → $DMG_PATH"
