#!/bin/bash
# Build Ooid.app and package into a DMG.
#
#   Scripts/build-dmg.sh              # release build + app + signed + dmg
#   SKIP_BUILD=1 Scripts/build-dmg.sh # reuse existing .build/release/Ooid
#   VERSION=v1.2.3 Scripts/build-dmg.sh # version for Info.plist (CI passes the tag)
#
# Distribution signing (otherwise the app is signed ad-hoc):
#   SIGN_IDENTITY="Developer ID Application"   codesign identity (a substring is enough)
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD   also notarize and staple the DMG
#   NOTARY_PROFILE=ooid                         or a `notarytool store-credentials` profile
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Ooid.app"
DMG="dist/Ooid.dmg"
APP_ICON_SRC="Sources/Ooid/AppIcon.png"
ICON_BUNDLE_SRC="Sources/Ooid/wallpaper.icon"

# Sparkle orders updates by this number, so a malformed one could break updates.
VERSION="${VERSION:-0.0.0}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "Bad VERSION: $VERSION" >&2; exit 1; }

if [ -z "${SKIP_BUILD:-}" ]; then
  swift build -c release
fi

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- Binary ------------------------------------------------------------------
cp .build/release/Ooid "$APP/Contents/MacOS/Ooid"
chmod +x "$APP/Contents/MacOS/Ooid"

# --- Resources (flat) --------------------------------------------------------
# We used to ship SPM's `Ooid_Ooid.bundle` sub-directory, but macOS 26
# tightened Bundle(url:) validation and refused it — crashing Bundle.module
# at launch. The code now looks everything up through Bundle.main, so we
# just stage resources flat in Contents/Resources.
cp "$(find .build/release/Ooid_Ooid.bundle -name Shaders.metal | head -1)" "$APP/Contents/Resources/Shaders.metal"

# --- Sparkle + licenses ------------------------------------------------------
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"

# --- Icons -------------------------------------------------------------------
# .icon package — used at runtime (NSImage) so macOS 26 renders the native
# glass / material Dock icon.
cp -R "$ICON_BUNDLE_SRC" "$APP/Contents/Resources/AppIcon.icon"
# Pre-Tahoe PNG fallback — used at runtime if NSImage can't open the .icon.
cp "$APP_ICON_SRC" "$APP/Contents/Resources/AppIcon.png"

# .icns — used by Info.plist's CFBundleIconFile on pre-Tahoe for Finder,
# Launchpad, cmd-tab, etc.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$APP_ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
sips -z 32 32   "$APP_ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 64 64   "$APP_ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 256 256 "$APP_ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 512 512 "$APP_ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
cp "$APP_ICON_SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- Info.plist --------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Ooid</string>
    <key>CFBundleExecutable</key><string>Ooid</string>
    <key>CFBundleIdentifier</key><string>com.magicsk.Ooid</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Ooid</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 magic_sk. Free software under GPL-3.0, with no warranty. Source: github.com/magicsk/ooid</string>
    <key>SUFeedURL</key><string>https://github.com/magicsk/ooid/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>6ctCXF63nBQFl43NWb2/wUfnADbW5RDWTDHqJiSEyjs=</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# --- Sign --------------------------------------------------------------------
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  # Inside out, as Sparkle's docs lay it out. --deep would skip the hardened
  # runtime and timestamp on the nested code, and notarization needs both.
  sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
  S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$S/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$S/XPCServices/Downloader.xpc"
  sign "$S/Autoupdate" "$S/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

# --- DMG ---------------------------------------------------------------------
STAGING=$(mktemp -d)/ooid-dmg-staging
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Ooid" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

# --- Notarize ----------------------------------------------------------------
# One submission for the DMG covers the app inside it; the stapled ticket lets
# Gatekeeper pass both without a network check.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  NOTARY=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
if [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if [ -n "${NOTARY+x}" ]; then
    OUT=$(xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --output-format json)
    ID=$(plutil -extract id raw -o - - <<<"$OUT")
    if [ "$(plutil -extract status raw -o - - <<<"$OUT")" != "Accepted" ]; then
      xcrun notarytool log "$ID" "${NOTARY[@]}"
      echo "Notarization failed: $OUT" >&2
      exit 1
    fi
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  fi
fi

echo
echo "✓ Built  $APP"
echo "✓ Signed $([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY")$([ -n "${NOTARY+x}" ] && [ "$IDENTITY" != "-" ] && echo ", notarized")"
echo "✓ DMG    $DMG ($(du -h "$DMG" | cut -f1))"
