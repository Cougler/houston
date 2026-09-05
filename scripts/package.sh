#!/bin/bash
# Packages Houston as a signed (ad-hoc unless SIGN_ID is set) DMG.
#
#   scripts/package.sh [version]
#
# Output: dist/Houston.dmg (and the intermediate dist/Houston.app).
# The release build is universal (arm64 + x86_64); libghostty is statically
# linked, so the bundle carries no frameworks — just the binary, the SwiftPM
# resource bundle (icons, skills), and the app icon.
#
# With a Developer ID SIGN_ID, the DMG is also signed, notarized (keychain
# profile "houston-notary"; set NOTARIZE=0 to skip), and stapled — ready to
# distribute with no Gatekeeper warning.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
SIGN_ID="${SIGN_ID:--}" # "-" = ad-hoc

echo "→ swift build -c release (universal)"
swift build -c release --arch arm64 --arch x86_64

PRODUCTS=".build/apple/Products/Release"
APP="dist/Houston.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ assembling $APP"
cp "$PRODUCTS/Houston" "$APP/Contents/MacOS/Houston"
# Bundle.module finds this next to the app's Resources.
cp -R "$PRODUCTS/Houston_Houston.bundle" "$APP/Contents/Resources/"

echo "→ AppIcon.icns"
ICONSET="dist/AppIcon.iconset"
mkdir -p "$ICONSET"
# Everything downscales from the 1024 master — the _rounded variant,
# because macOS does NOT mask Dock icons itself; Appicon1024.png is the
# raw square artwork (the rounded file is that art behind the old
# master's measured corner radius, 152px at 1024). Filling the 512@2x
# slot with real pixels is what keeps the macOS 26 app switcher sharp —
# it renders larger than 512 and upscaling the 512 slot looked blurry.
SRC="Sources/Houston/Resources/icons/Appicon1024_rounded.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Houston</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.cougler.houston</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Houston</string>
	<key>CFBundleDisplayName</key><string>Houston</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSAppTransportSecurity</key>
	<dict><key>NSAllowsLocalNetworking</key><true/></dict>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

echo "→ codesign ($SIGN_ID)"
codesign --force --deep --options runtime -s "$SIGN_ID" "$APP" 2>/dev/null \
  || codesign --force --deep -s "$SIGN_ID" "$APP"

echo "→ DMG (space-themed drag-to-Applications window)"
STAGING="dist/dmg"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp scripts/dmg-background.png "$STAGING/.background/background.png"
rm -f dist/Houston.dmg dist/Houston-rw.dmg
# Read-write image first: Finder lays out the window (background, icon
# positions, view options — saved into the volume's .DS_Store), then the
# result is compressed. Regenerate the art with scripts/dmg-background.swift.
hdiutil detach /Volumes/Houston >/dev/null 2>&1 || true
hdiutil create -volname "Houston" -srcfolder "$STAGING" -ov -format UDRW \
  -fs HFS+ -size 120m dist/Houston-rw.dmg >/dev/null
hdiutil attach dist/Houston-rw.dmg -readwrite -noverify -noautoopen >/dev/null
sleep 1
osascript <<'OSA'
tell application "Finder"
  tell disk "Houston"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 860, 588}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    -- Finder picks black/white label text from the background COLOR's
    -- luminance; black here nudges labels white under the dark picture.
    set background color of viewOptions to {0, 0, 0}
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Houston.app" of container window to {165, 205}
    set position of item "Applications" of container window to {495, 205}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach /Volumes/Houston >/dev/null
hdiutil convert dist/Houston-rw.dmg -format UDZO -o dist/Houston.dmg >/dev/null
rm -f dist/Houston-rw.dmg
rm -rf "$STAGING"

# Notarize when signed with a real identity (skip for ad-hoc builds).
if [ "$SIGN_ID" != "-" ] && [ "${NOTARIZE:-1}" = "1" ]; then
  echo "→ codesign DMG"
  codesign --force --sign "$SIGN_ID" dist/Houston.dmg

  echo "→ notarize (this waits on Apple, usually a few minutes)"
  xcrun notarytool submit dist/Houston.dmg \
    --keychain-profile houston-notary --wait

  echo "→ staple"
  xcrun stapler staple dist/Houston.dmg
  spctl -a -t open --context context:primary-signature dist/Houston.dmg \
    && echo "✓ Gatekeeper: accepted"
fi

echo "✓ $(du -h dist/Houston.dmg | cut -f1 | tr -d ' ')  dist/Houston.dmg"
