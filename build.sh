#!/usr/bin/env bash
# Build Anooki.app — a universal (arm64 + x86_64) macOS LSUIElement app.
# Listens for the screensaver-action distributed notification and overlays the
# Anooki animations fullscreen via WKWebView + Ruffle.
#
# Optional environment variables (required for Tahoe runtime):
#
#   SIGNING_IDENTITY  "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE    notarytool keychain credential profile name
#
# Example:
#   SIGNING_IDENTITY="Developer ID Application: Xavier Garcia (249E4T93U9)" \
#       NOTARY_PROFILE=anooki-notary ./build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="Anooki"
BUNDLE="$HERE/build/$NAME.app"
CONTENTS="$BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
ENTITLEMENTS="$HERE/src/Anooki.entitlements"
MIN_OS="13.0"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# 0. Sanity
if ! command -v swiftc >/dev/null; then
  echo "ERROR: swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi
if [ ! -d "$HERE/Resources/ruffle" ] || [ -z "$(ls -A "$HERE/Resources/ruffle" 2>/dev/null)" ]; then
  echo "Ruffle not staged yet — running scripts/fetch-ruffle.sh"
  "$HERE/scripts/fetch-ruffle.sh"
fi
if [ -z "$(ls "$HERE/Resources/anims/"anim*.swf 2>/dev/null)" ]; then
  echo "ERROR: No anim*.swf files in Resources/anims/." >&2
  exit 1
fi

# 1. Fresh output
rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# 2. Compile per arch, lipo
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SDK="$(xcrun --show-sdk-path --sdk macosx)"

SWIFT_SOURCES=(
  "$HERE/src/main.swift"
  "$HERE/src/AppDelegate.swift"
)

build_arch () {
  local arch="$1"
  echo "→ Compiling for $arch"
  xcrun -sdk macosx swiftc \
    -target "${arch}-apple-macos${MIN_OS}" \
    -sdk "$SDK" \
    -module-name "$NAME" \
    -O \
    -framework Cocoa \
    -framework WebKit \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "$TMP/${NAME}-${arch}" \
    "${SWIFT_SOURCES[@]}"
}

build_arch arm64
build_arch x86_64

echo "→ Creating universal binary"
xcrun lipo -create "$TMP/${NAME}-arm64" "$TMP/${NAME}-x86_64" -output "$MACOS_DIR/$NAME"

# 3. Info.plist + resources
cp "$HERE/src/Info.plist" "$CONTENTS/Info.plist"

cp "$HERE/Resources/index.html" "$RES_DIR/"
cp "$HERE/Resources/player.js" "$RES_DIR/"
mkdir -p "$RES_DIR/anims" "$RES_DIR/ruffle"
cp "$HERE/Resources/anims/"anim*.swf "$RES_DIR/anims/"
cp -R "$HERE/Resources/ruffle/." "$RES_DIR/ruffle/"
# Original Screentime engine assets — player.js tries movie.swf first.
for f in movie.swf STFProxy.swf preloader.swf \
         ephemeride.xml underground.xml \
         anniv-evenements.xml anniv-people.xml anniv-personnages.xml; do
  if [ -f "$HERE/Resources/$f" ]; then
    cp "$HERE/Resources/$f" "$RES_DIR/"
  fi
done

# 4. Clean xattrs
echo "→ Cleaning extended attributes"
xattr -cr "$BUNDLE"
find "$BUNDLE" -name ".DS_Store" -delete

# 5. Sign
if [ -n "$SIGNING_IDENTITY" ]; then
  echo "→ Signing with Developer ID: $SIGNING_IDENTITY"
  codesign --force --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$MACOS_DIR/$NAME"
  codesign --force --timestamp \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$BUNDLE"
  echo "→ Verifying signature"
  codesign --verify --deep --strict --verbose=2 "$BUNDLE"
else
  echo "→ Ad-hoc signing (for local testing only)"
  codesign --force --deep --sign - --timestamp=none "$BUNDLE"
fi

# 6. Notarize
if [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "→ Zipping for notarization"
  ZIP="$HERE/build/${NAME}.app.zip"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$BUNDLE" "$ZIP"
  echo "→ Submitting to Apple notary service"
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  echo "→ Stapling"
  xcrun stapler staple "$BUNDLE"
  xcrun stapler validate "$BUNDLE"
  rm -f "$ZIP"
fi

# 7. Report
echo
echo "✓ Built: $BUNDLE"
codesign -dv --verbose=2 "$BUNDLE" 2>&1 | head -6
echo
echo "Run:"
echo "  open \"$BUNDLE\""
echo
echo "Install to ~/Applications:"
echo "  cp -R \"$BUNDLE\" ~/Applications/"
echo
echo "Set to start at login:"
echo "  System Settings → General → Login Items → drag Anooki.app into 'Open at Login'"
