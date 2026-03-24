#!/bin/bash
# Build Blitz.pkg installer from the Swift .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env (existing env vars take precedence)
[ -f "$ROOT_DIR/.env" ] && set -a && source "$ROOT_DIR/.env" && set +a

# Config
APP_NAME="Blitz"
IDENTIFIER="com.blitz.macos"
VERSION=$(node -e "const p=JSON.parse(require('fs').readFileSync('$ROOT_DIR/package.json','utf8')); process.stdout.write(p.version)" 2>/dev/null \
  || grep '"version"' "$ROOT_DIR/package.json" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')

echo "Building $APP_NAME.pkg v$VERSION"

# Paths
SOURCE_APP="$ROOT_DIR/.build/$APP_NAME.app"
PKG_SCRIPTS="$ROOT_DIR/scripts/pkg-scripts"
ENTITLEMENTS="$ROOT_DIR/scripts/Entitlements.plist"
BUILD_DIR="$ROOT_DIR/build/pkg"
OUTPUT_PKG="$ROOT_DIR/build/$APP_NAME-$VERSION.pkg"

# Verify .app exists
if [ ! -d "$SOURCE_APP" ]; then
    echo "ERROR: $SOURCE_APP not found."
    echo "Run 'npm run build:app' (or 'bash scripts/bundle.sh release') first."
    exit 1
fi

# Clean build dir and stale .pkg files
rm -rf "$BUILD_DIR"
rm -f "$ROOT_DIR/build/$APP_NAME-"*.pkg
mkdir -p "$BUILD_DIR/payload"

# Copy app to build dir (use ditto to avoid ._  Apple Double files)
echo "Copying $SOURCE_APP to payload..."
ditto "$SOURCE_APP" "$BUILD_DIR/payload/$APP_NAME.app"

if [ ! -d "$BUILD_DIR/payload/$APP_NAME.app" ]; then
    echo "ERROR: Failed to copy app to payload directory"
    exit 1
fi

# Remove extended attributes that can cause issues
echo "Removing extended attributes..."
xattr -cr "$BUILD_DIR/payload/$APP_NAME.app" 2>/dev/null || true

# --- Re-sign .app after copy (ditto + xattr invalidate the signature) ---
APP_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
APP_PAYLOAD="$BUILD_DIR/payload/$APP_NAME.app"

if [ -n "$APP_SIGNING_IDENTITY" ]; then
    echo "Re-signing .app bundle..."

    # Sign nested binaries first (inside out)
    find "$APP_PAYLOAD/Contents/Resources" -type f \( -name "*.node" -o -name "*.dylib" \) 2>/dev/null | while read -r f; do
        codesign --force --options runtime --timestamp \
            --sign "$APP_SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$f"
    done
    if [ -f "$APP_PAYLOAD/Contents/Helpers/blitz-macos-mcp" ]; then
        codesign --force --options runtime --timestamp \
            --sign "$APP_SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$APP_PAYLOAD/Contents/Helpers/blitz-macos-mcp"
    fi

    # Re-sign the main app bundle (must be last)
    codesign --force --options runtime --timestamp \
        --sign "$APP_SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PAYLOAD"

    echo "   Re-signed: $APP_PAYLOAD"

    # Verify
    codesign --verify --deep --strict "$APP_PAYLOAD" \
        && echo "   Signature valid" \
        || { echo "ERROR: Signature verification failed"; exit 1; }
else
    echo "WARNING: APPLE_SIGNING_IDENTITY not set — .app will not be re-signed"
fi

# Stage pkg scripts with non-standard names so pkgbuild doesn't auto-detect
# them. We reference them as bundle-specific scripts via component plist so
# BundleInstallScriptTimeout can be set.
SCRIPTS_STAGING="$BUILD_DIR/scripts"
mkdir -p "$SCRIPTS_STAGING"
cp "$PKG_SCRIPTS/preinstall"  "$SCRIPTS_STAGING/blitz-preinstall"
cp "$PKG_SCRIPTS/postinstall" "$SCRIPTS_STAGING/blitz-postinstall"
chmod 755 "$SCRIPTS_STAGING/blitz-preinstall" "$SCRIPTS_STAGING/blitz-postinstall"
xattr -cr "$SCRIPTS_STAGING" 2>/dev/null || true

# Generate component plist
echo "Generating component plist..."
pkgbuild --analyze --root "$BUILD_DIR/payload" "$BUILD_DIR/component.plist"

# Prevent macOS from relocating the app to a previously-seen location
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$BUILD_DIR/component.plist"

# Bundle-specific scripts with 1-hour timeout (default 10 min is too short
# for postinstall on slow connections — Node + Ruby + Python + idb downloads)
/usr/libexec/PlistBuddy -c "Add :0:BundlePreInstallScriptPath  string blitz-preinstall"    "$BUILD_DIR/component.plist"
/usr/libexec/PlistBuddy -c "Add :0:BundlePostInstallScriptPath string blitz-postinstall"   "$BUILD_DIR/component.plist"
/usr/libexec/PlistBuddy -c "Add :0:BundleInstallScriptTimeout  integer 3600"               "$BUILD_DIR/component.plist"

echo "Component plist:"
cat "$BUILD_DIR/component.plist"
echo ""

# Build component package
echo "Building component package..."
pkgbuild \
    --root "$BUILD_DIR/payload" \
    --component-plist "$BUILD_DIR/component.plist" \
    --install-location /Applications \
    --scripts "$SCRIPTS_STAGING" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    "$BUILD_DIR/$APP_NAME-component.pkg"

if [ ! -f "$BUILD_DIR/$APP_NAME-component.pkg" ]; then
    echo "ERROR: Failed to create component package"
    exit 1
fi

# Size sanity check
PKG_SIZE=$(stat -f%z "$BUILD_DIR/$APP_NAME-component.pkg" 2>/dev/null || echo 0)
if [ "$PKG_SIZE" -gt 1000000 ]; then
    echo "   Component package looks good ($PKG_SIZE bytes)"
else
    echo "   ERROR: Component package too small or missing ($PKG_SIZE bytes)"
    exit 1
fi

# Create distribution.xml
echo "Creating distribution.xml..."
cat > "$BUILD_DIR/distribution.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Blitz</title>
    <organization>com.blitz</organization>
    <domains enable_localSystem="true"/>
    <options hostArchitectures="arm64,x86_64" rootVolumeOnly="true"/>
    <options customize="never" require-scripts="true" rootVolumeOnly="true"/>

    <choices-outline>
        <line choice="default">
            <line choice="$IDENTIFIER"/>
        </line>
    </choices-outline>

    <choice id="default"/>
    <choice id="$IDENTIFIER" visible="false">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>

    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">$APP_NAME-component.pkg</pkg-ref>
</installer-gui-script>
EOF

# Build final product
echo "Building final product..."
productbuild \
    --distribution "$BUILD_DIR/distribution.xml" \
    --package-path "$BUILD_DIR" \
    "$OUTPUT_PKG"

if [ ! -f "$OUTPUT_PKG" ]; then
    echo "ERROR: Failed to create final package"
    exit 1
fi

# --- Sign the .pkg with Developer ID Installer ---
INSTALLER_IDENTITY="${APPLE_INSTALLER_IDENTITY:-}"
if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "Signing .pkg with: $INSTALLER_IDENTITY"
    UNSIGNED_PKG="${OUTPUT_PKG%.pkg}-unsigned.pkg"
    mv "$OUTPUT_PKG" "$UNSIGNED_PKG"
    productsign --sign "$INSTALLER_IDENTITY" "$UNSIGNED_PKG" "$OUTPUT_PKG"
    rm "$UNSIGNED_PKG"
    echo "   Signed: $OUTPUT_PKG"
else
    echo "WARNING: APPLE_INSTALLER_IDENTITY not set — .pkg will be unsigned"
    echo "   Set it to: Developer ID Installer: Your Name (YOUR_TEAM_ID)"
fi

# --- Notarize + staple ---
if [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
    echo "Submitting .pkg for notarization..."
    xcrun notarytool submit "$OUTPUT_PKG" \
        --key "$APPLE_API_KEY_PATH" \
        --key-id "$APPLE_API_KEY" \
        --issuer "$APPLE_API_ISSUER" \
        --wait
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$OUTPUT_PKG"
    echo "   Notarized and stapled: $OUTPUT_PKG"
elif [ -n "$INSTALLER_IDENTITY" ]; then
    echo "WARNING: Notarization env vars not set — .pkg is signed but not notarized"
    echo "   Set APPLE_API_KEY, APPLE_API_KEY_PATH, APPLE_API_ISSUER to enable"
fi

# Clean payload so Spotlight won't index it
rm -rf "$BUILD_DIR/payload"

echo ""
echo "Built: $OUTPUT_PKG"
echo "   Size: $(du -h "$OUTPUT_PKG" | cut -f1)"
echo ""
echo "To install:"
echo "   open $OUTPUT_PKG"
echo ""
echo "Or via command line:"
echo "   sudo installer -pkg $OUTPUT_PKG -target / -verbose"
echo ""
echo "Done."
