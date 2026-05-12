#!/bin/zsh
set -e

APP_NAME="GONE Player Beta 0.8"
SCHEME="GONE"
ENTITLEMENTS="$(dirname "$0")/GONE/GONE_release.entitlements"
OUT_DIR="$HOME/Desktop"
DMG_PATH="$OUT_DIR/$APP_NAME.dmg"

echo "→ Looking for Release build in DerivedData..."
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "$SCHEME.app" -path "*/Release/*" | head -1)

if [[ -z "$APP_PATH" ]]; then
  echo "✗ Release build not found. Build Release in Xcode first (Cmd+B with Release scheme)."
  exit 1
fi

echo "  Found: $APP_PATH"

echo "→ Setting display name..."
/usr/libexec/PlistBuddy \
  -c "Delete :CFBundleDisplayName" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleDisplayName string $APP_NAME" \
  "$APP_PATH/Contents/Info.plist"

echo "→ Signing ad-hoc with entitlements..."
codesign --force --deep --sign - \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

echo "→ Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "✓ Done → $DMG_PATH"
open "$OUT_DIR"
