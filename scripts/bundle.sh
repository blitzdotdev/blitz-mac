#!/bin/bash
# Creates a proper macOS .app bundle from the SPM build.
# Signs with Developer ID so TCC grants persist across rebuilds.
set -e

CONFIG="${1:-release}"
APP_NAME="Blitz"
BUNDLE_DIR=".build/${APP_NAME}.app"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Load .env (existing env vars take precedence)
[ -f "$ROOT_DIR/.env" ] && set -a && source "$ROOT_DIR/.env" && set +a

SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
ENTITLEMENTS="$ROOT_DIR/scripts/Entitlements.plist"
TIMESTAMP_MODE="${CODESIGN_TIMESTAMP:-auto}"

if [ "$CONFIG" = "debug" ] && [ "$TIMESTAMP_MODE" = "auto" ]; then
    TIMESTAMP_MODE="none"
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "WARNING: APPLE_SIGNING_IDENTITY not set, falling back to ad-hoc signing."
    echo "         TCC will require re-approval on every rebuild."
    SIGNING_IDENTITY="-"
fi

# Read version from package.json
VERSION=$(node -e "const p=JSON.parse(require('fs').readFileSync('$ROOT_DIR/package.json','utf8')); process.stdout.write(p.version)" 2>/dev/null \
  || grep '"version"' "$ROOT_DIR/package.json" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')
echo "Building $APP_NAME.app v$VERSION ($CONFIG)..."

# Build
swift build -c "$CONFIG"

# Create .app structure
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

# Copy binary
cp ".build/${CONFIG}/${APP_NAME}" "$BUNDLE_DIR/Contents/MacOS/${APP_NAME}"

# Generate app icon (.icns) from PNG
ICON_PNG="$ROOT_DIR/src/resources/blitz-icon.png"
ICON_ICNS="$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_PNG" ]; then
    if [ ! -f "$ICON_ICNS" ] || [ "$ICON_PNG" -nt "$ICON_ICNS" ]; then
        ICONSET_DIR=$(mktemp -d)/Blitz.iconset
        mkdir -p "$ICONSET_DIR"
        for size in 16 32 128 256 512; do
            sips -z $size $size "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null 2>&1
            double=$((size * 2))
            sips -z $double $double "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null 2>&1
        done
        iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
        rm -rf "$(dirname "$ICONSET_DIR")"
        echo "Generated AppIcon.icns"
    fi
fi

# Copy SPM resource bundles into Contents/Resources/ (standard macOS location).
# NOTE: SPM's generated Bundle.module uses bundleURL (= .app root) which won't find
# bundles here. We use a custom Bundle.appResources accessor instead — see AppBundle.swift.
for bundle_dir in .build/${CONFIG}/*.bundle; do
    if [ -d "$bundle_dir" ]; then
        cp -R "$bundle_dir" "$BUNDLE_DIR/Contents/Resources/"
        echo "Copied $(basename "$bundle_dir") to Contents/Resources/"
    fi
done

# Embed Claude skills in .app bundle (installed to ~/.claude/skills/ at app startup)
SKILLS_SRC="$ROOT_DIR/.claude/skills"
SKILLS_DST="$BUNDLE_DIR/Contents/Resources/claude-skills"
if [ -d "$SKILLS_SRC" ]; then
    rm -rf "$SKILLS_DST"
    cp -R "$SKILLS_SRC" "$SKILLS_DST"
    echo "Embedded Claude skills in .app bundle"
fi

# Embed pkg-scripts in .app for auto-updater (mirrors Tauri pattern)
PKG_SCRIPTS_SRC="$ROOT_DIR/scripts/pkg-scripts"
PKG_SCRIPTS_DST="$BUNDLE_DIR/Contents/Resources/pkg-scripts"
if [ -d "$PKG_SCRIPTS_SRC" ]; then
    mkdir -p "$PKG_SCRIPTS_DST"
    for script in "$PKG_SCRIPTS_SRC"/*; do
        [ -f "$script" ] || continue
        cp "$script" "$PKG_SCRIPTS_DST/"
        chmod 755 "$PKG_SCRIPTS_DST/$(basename "$script")"
    done
    echo "Embedded pkg-scripts in .app bundle"
fi

# Write Info.plist with correct version
cat > "$BUNDLE_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Blitz</string>
    <key>CFBundleIdentifier</key>
    <string>com.blitz.macos</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Blitz</string>
    <key>CFBundleDisplayName</key>
    <string>Blitz</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Blitz needs screen recording access to capture the iOS Simulator display.</string>
    <key>NSCameraUsageDescription</key>
    <string>Blitz needs camera access to capture physical iOS device screens via USB.</string>
</dict>
</plist>
PLIST

# Remove stale codesign temp files from previous failed signing attempts
find "$BUNDLE_DIR" -name "*.cstemp" -delete 2>/dev/null || true

codesign_bundle_path() {
    local target="$1"

    if [ "$SIGNING_IDENTITY" = "-" ]; then
        codesign --force --sign - --entitlements "$ENTITLEMENTS" "$target"
        return
    fi

    if [ "$TIMESTAMP_MODE" = "none" ]; then
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$target"
        return
    fi

    if ! codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$target" 2>/dev/null; then
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$target"
    fi
}

# Sign nested native binaries first (inside-out — required for notarization)
if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "Signing native dependencies..."
    find "$BUNDLE_DIR/Contents/Resources" -type f \( -name "*.node" -o -name "*.dylib" \) 2>/dev/null | while read -r f; do
        codesign_bundle_path "$f" 2>/dev/null || true
        echo "  Signed: $f"
    done
fi

# Sign the .app bundle (must be after nested signing)
if [ "$SIGNING_IDENTITY" != "-" ] && [ "$TIMESTAMP_MODE" = "auto" ]; then
    if ! codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$BUNDLE_DIR" &>/dev/null; then
        echo "Timestamp server unavailable, signing without timestamp..."
        codesign --force --options runtime --timestamp=none \
            --sign "$SIGNING_IDENTITY" \
            --entitlements "$ENTITLEMENTS" \
            "$BUNDLE_DIR"
    fi
else
    codesign_bundle_path "$BUNDLE_DIR"
fi

echo ""
echo "Built: $BUNDLE_DIR (v$VERSION)"
echo "Signed with: $SIGNING_IDENTITY"
echo "Launch with: open $BUNDLE_DIR"
