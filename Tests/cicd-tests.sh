#!/bin/bash
# CI/CD Migration Test Suite — blitz-macos
# Tests every change made in the cicd-migration plan.
#
# Usage (from blitz-macos root):
#   bash tests/cicd-tests.sh
#   bash tests/cicd-tests.sh --verbose   # show stdout from each test
set -uo pipefail

# ── Terminal colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

PASS=0; FAIL=0; ERRORS=()
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Assertions ────────────────────────────────────────────────────────────────

ok() {
    echo -e "  ${GREEN}✓${RESET} $1"
    ((PASS++)) || true
}

fail() {
    local desc="$1" detail="${2:-}"
    echo -e "  ${RED}✗${RESET} $desc"
    [ -n "$detail" ] && echo -e "    ${YELLOW}→${RESET} $detail"
    ((FAIL++)) || true
    ERRORS+=("$desc")
}

section() {
    echo ""
    echo -e "${BOLD}$1${RESET}"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then ok "$desc"
    else fail "$desc" "expected '$expected', got '$actual'"; fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then ok "$desc"
    else fail "$desc" "expected to contain: $needle"; fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then ok "$desc"
    else fail "$desc" "should NOT contain: $needle"; fi
}

assert_file_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF "$needle" "$file" 2>/dev/null; then ok "$desc"
    else fail "$desc" "file $file does not contain: $needle"; fi
}

assert_exits_ok() {
    local desc="$1"; shift
    local out
    if out=$("$@" 2>&1); then ok "$desc"
    else fail "$desc" "exited non-zero; output: $out"; fi
}

assert_exits_fail() {
    local desc="$1"; shift
    local out
    if out=$("$@" 2>&1); then fail "$desc" "expected non-zero exit but got 0"
    else ok "$desc"; fi
}

# ── Temp dir helpers ──────────────────────────────────────────────────────────

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Create a minimal fake project in $1 with version $2
make_project() {
    local dir="$1" ver="${2:-1.2.3}"
    mkdir -p "$dir"
    cat > "$dir/package.json" << JSON
{
  "name": "blitz-macos",
  "version": "$ver",
  "type": "module",
  "private": true,
  "scripts": {
    "build:sidecar":   "node scripts/build-server.mjs",
    "build:app":       "bash scripts/bundle.sh release",
    "build:pkg":       "bash scripts/build-pkg.sh",
    "deploy":          "bash scripts/deploy-pkg.sh",
    "deploy:snapshot": "bash scripts/deploy-pkg.sh --snapshot",
    "release-tag":     "npm version patch && npm run build:sidecar && npm run build:app && npm run build:pkg && npm run deploy",
    "release":         "npm version patch --no-git-tag-version && npm run build:sidecar && npm run build:app && npm run build:pkg && npm run deploy",
    "bundle:all":      "echo ok"
  },
  "devDependencies": {
    "@repalash/rclone.js": "*"
  }
}
JSON
    mkdir -p "$dir/scripts/pkg-scripts" "$dir/build" "$dir/.build"
    # Copy real scripts so tests run against them
    cp "$ROOT_DIR/scripts/bundle.sh"         "$dir/scripts/bundle.sh"
    cp "$ROOT_DIR/scripts/build-pkg.sh"      "$dir/scripts/build-pkg.sh"
    cp "$ROOT_DIR/scripts/deploy-pkg.sh"     "$dir/scripts/deploy-pkg.sh"
    cp "$ROOT_DIR/scripts/build-server.mjs"  "$dir/scripts/build-server.mjs"
    cp "$ROOT_DIR/scripts/Entitlements.plist" "$dir/scripts/Entitlements.plist"
    cp "$ROOT_DIR/scripts/pkg-scripts/preinstall"  "$dir/scripts/pkg-scripts/preinstall"
    cp "$ROOT_DIR/scripts/pkg-scripts/postinstall" "$dir/scripts/pkg-scripts/postinstall"
}

# Create a mock-bin directory with stub commands that replace system tools.
# Returns the path in $MOCK_BIN.
make_mock_bin() {
    local dir="$1"
    mkdir -p "$dir"

    # swift: creates a fake binary so bundle.sh can proceed
    cat > "$dir/swift" << 'SH'
#!/bin/bash
CONFIG="release"
prev=""
for arg in "$@"; do
    [ "$prev" = "-c" ] && CONFIG="$arg"
    prev="$arg"
done
mkdir -p ".build/$CONFIG"
printf '#!/bin/bash\necho mock-blitz\n' > ".build/$CONFIG/Blitz"
chmod +x ".build/$CONFIG/Blitz"
exit 0
SH

    # codesign: no-op for all invocations
    cat > "$dir/codesign" << 'SH'
#!/bin/bash
# Accept --verify --deep --strict to simulate successful verification
exit 0
SH

    # pkgbuild: handle --analyze (produces valid component.plist) and build (produces .pkg)
    cat > "$dir/pkgbuild" << 'SH'
#!/bin/bash
if [[ "$*" == *"--analyze"* ]]; then
    # --analyze: write valid component plist to the last *.plist arg
    plist_out=""
    for arg in "$@"; do case "$arg" in *.plist) plist_out="$arg" ;; esac; done
    [ -n "$plist_out" ] && cat > "$plist_out" << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key><true/>
        <key>BundleIsVersionChecked</key><true/>
        <key>BundleIsRelocatable</key><false/>
        <key>BundleOverwriteAction</key><string>upgrade</string>
        <key>RootRelativeBundlePath</key><string>Blitz.app</string>
    </dict>
</array>
</plist>
XML
else
    # build: create fake .pkg (>1 MB to pass size check)
    for arg in "$@"; do
        case "$arg" in *.pkg) dd if=/dev/zero of="$arg" bs=1024 count=1500 2>/dev/null ;; esac
    done
fi
exit 0
SH

    # productbuild: copy the component pkg as the output
    cat > "$dir/productbuild" << 'SH'
#!/bin/bash
output=""
for arg in "$@"; do
    case "$arg" in *.pkg) output="$arg" ;; esac
done
[ -n "$output" ] && dd if=/dev/zero of="$output" bs=1024 count=1500 2>/dev/null
exit 0
SH

    # productsign: move unsigned to signed
    cat > "$dir/productsign" << 'SH'
#!/bin/bash
src="" dst=""
for arg in "$@"; do
    case "$arg" in
        --sign) ;;
        *) [ -z "$src" ] && src="$arg" || dst="$arg" ;;
    esac
done
[ -n "$src" ] && [ -n "$dst" ] && mv "$src" "$dst" 2>/dev/null || true
exit 0
SH

    # PlistBuddy: manipulate plist commands silently
    cat > "$dir/PlistBuddy" << 'SH'
#!/bin/bash
exit 0
SH

    # xcrun: no-op for notarytool / stapler
    cat > "$dir/xcrun" << 'SH'
#!/bin/bash
exit 0
SH

    # ditto: just use cp -R
    cat > "$dir/ditto" << 'SH'
#!/bin/bash
# ditto src dst
src="${@:(-2):1}"
dst="${@:(-1)}"
cp -R "$src" "$dst"
exit 0
SH

    # xattr: no-op
    cat > "$dir/xattr" << 'SH'
#!/bin/bash
exit 0
SH

    # shasum: return a fake checksum
    cat > "$dir/shasum" << 'SH'
#!/bin/bash
echo "aabbccdd1122334455667788aabbccdd1122334455667788aabbccdd11223344  $@"
exit 0
SH

    # rclone: no-op (for deploy tests that get past credential check)
    cat > "$dir/rclone" << 'SH'
#!/bin/bash
# Fake rclone: echo the command, succeed
case "$1" in
    cat) echo '{"version":"0.0.1"}' ;;  # fake latest.json
    *) true ;;
esac
exit 0
SH

    chmod +x "$dir"/*
    # PlistBuddy lives at /usr/libexec/PlistBuddy — override via wrapper
    mkdir -p "$dir/../libexec"
    cp "$dir/PlistBuddy" "$dir/../libexec/PlistBuddy"
    chmod +x "$dir/../libexec/PlistBuddy"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: package.json
# ─────────────────────────────────────────────────────────────────────────────
section "1. package.json"

PKG="$ROOT_DIR/package.json"

# Valid JSON
if node -e "JSON.parse(require('fs').readFileSync('$PKG','utf8'))" 2>/dev/null; then
    ok "valid JSON"
else
    fail "valid JSON" "JSON.parse failed"
fi

# Required scripts
for script in "build:sidecar" "build:app" "build:pkg" "deploy" "deploy:snapshot" "release-tag" "release" "bundle:all"; do
    content=$(cat "$PKG")
    assert_contains "script '$script' exists" "\"$script\"" "$content"
done

# release-tag chains all steps
RT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$PKG','utf8')).scripts['release-tag'])")
assert_contains "release-tag runs npm version patch"   "npm version patch"  "$RT"
assert_contains "release-tag runs build:sidecar"       "build:sidecar"      "$RT"
assert_contains "release-tag runs build:app"           "build:app"          "$RT"
assert_contains "release-tag runs build:pkg"           "build:pkg"          "$RT"
assert_contains "release-tag runs deploy"              "npm run deploy"     "$RT"

# version is semver
VERSION=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$PKG','utf8')).version)")
if echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then ok "version is semver ($VERSION)"
else fail "version is semver" "got: $VERSION"; fi

# has @repalash/rclone.js devDep
assert_contains "has @repalash/rclone.js devDependency" "@repalash/rclone.js" "$(cat "$PKG")"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: bundle.sh — version injection
# ─────────────────────────────────────────────────────────────────────────────
section "2. bundle.sh — version injection into Info.plist"

T="$TMPROOT/bundle-version" && make_project "$T" "2.7.4"
MOCK_BIN="$T/mock-bin" && make_mock_bin "$MOCK_BIN"
mkdir -p "$T/dist/server/template" && echo "test" > "$T/dist/server/template/file.txt"

out=$(cd "$T" && PATH="$MOCK_BIN:$PATH" \
    APPLE_SIGNING_IDENTITY="" \
    bash scripts/bundle.sh release 2>&1) || true

PLIST="$T/.build/Blitz.app/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    ok "Info.plist was created"
    plist_ver=$(grep -A1 'CFBundleShortVersionString' "$PLIST" | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    assert_eq "Info.plist version matches package.json" "2.7.4" "$plist_ver"
    plist_ver2=$(grep -A1 'CFBundleVersion' "$PLIST" | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
    assert_eq "CFBundleVersion matches package.json"    "2.7.4" "$plist_ver2"
else
    fail "Info.plist was created" "file missing: $PLIST (bundle.sh output: $out)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: bundle.sh — sidecar copy
# ─────────────────────────────────────────────────────────────────────────────
section "3. bundle.sh — sidecar bundled into .app/Contents/Resources"

SIDECAR_DST="$T/.build/Blitz.app/Contents/Resources/dist/server"
if [ -d "$SIDECAR_DST" ]; then
    ok "dist/server directory created in .app Resources"
    if [ -f "$SIDECAR_DST/template/file.txt" ]; then
        ok "sidecar file copied correctly"
    else
        fail "sidecar file copied correctly" "template/file.txt missing in $SIDECAR_DST"
    fi
else
    fail "dist/server directory created in .app Resources" "missing: $SIDECAR_DST"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: bundle.sh — missing sidecar is a warning, not a failure
# ─────────────────────────────────────────────────────────────────────────────
section "4. bundle.sh — missing dist/server warns, does not fail"

T2="$TMPROOT/bundle-nosidecar" && make_project "$T2" "1.0.0"
MOCK_BIN2="$T2/mock-bin" && make_mock_bin "$MOCK_BIN2"
# No dist/server directory created
out2=$(cd "$T2" && PATH="$MOCK_BIN2:$PATH" \
    APPLE_SIGNING_IDENTITY="" \
    bash scripts/bundle.sh release 2>&1)
exit_code=$?
if [ $exit_code -eq 0 ]; then ok "bundle.sh exits 0 even without dist/server"
else fail "bundle.sh exits 0 even without dist/server" "exited $exit_code"; fi
assert_contains "bundle.sh emits WARNING for missing dist/server" "WARNING" "$out2"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5: bundle.sh — correct bundle ID in Info.plist
# ─────────────────────────────────────────────────────────────────────────────
section "5. bundle.sh — Info.plist has correct bundle ID"

PLIST2="$T2/.build/Blitz.app/Contents/Info.plist"
if [ -f "$PLIST2" ]; then
    assert_file_contains "Info.plist has com.blitz.macos" "com.blitz.macos" "$PLIST2"
    if grep -q "dev.blitz.mac" "$PLIST2" 2>/dev/null; then
        fail "Info.plist does NOT have old dev.blitz.mac ID" "old ID found in Info.plist"
    else
        ok "Info.plist does NOT have old dev.blitz.mac ID"
    fi
else
    fail "Info.plist exists" "not found: $PLIST2"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6: build-pkg.sh — fails when .app is missing
# ─────────────────────────────────────────────────────────────────────────────
section "6. build-pkg.sh — exits non-zero when .build/Blitz.app is missing"

T3="$TMPROOT/pkg-no-app" && make_project "$T3" "1.0.0"
out3=$(cd "$T3" && bash scripts/build-pkg.sh 2>&1) && rc=0 || rc=$?
if [ $rc -ne 0 ]; then ok "build-pkg.sh exits non-zero when .app missing"
else fail "build-pkg.sh exits non-zero when .app missing" "exited 0"; fi
assert_contains "build-pkg.sh error mentions build:app" "build:app" "$out3"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7: build-pkg.sh — uses com.blitz.macos identifier
# ─────────────────────────────────────────────────────────────────────────────
section "7. build-pkg.sh — correct bundle ID (com.blitz.macos)"

# The IDENTIFIER is hardcoded in the script itself
assert_file_contains "build-pkg.sh contains com.blitz.macos" \
    "com.blitz.macos" "$ROOT_DIR/scripts/build-pkg.sh"

if grep -q "dev.blitz.mac" "$ROOT_DIR/scripts/build-pkg.sh" 2>/dev/null; then
    fail "build-pkg.sh does NOT contain old dev.blitz.mac" "old ID found"
else
    ok "build-pkg.sh does NOT contain old dev.blitz.mac"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8: build-pkg.sh — reads .app from .build/Blitz.app (not tauri output)
# ─────────────────────────────────────────────────────────────────────────────
section "8. build-pkg.sh — reads from .build/ (Swift SPM output, not Tauri)"

assert_file_contains "build-pkg.sh references .build/Blitz.app" \
    '.build/$APP_NAME.app' "$ROOT_DIR/scripts/build-pkg.sh"

if grep -q "src-tauri/target" "$ROOT_DIR/scripts/build-pkg.sh" 2>/dev/null; then
    fail "build-pkg.sh does NOT reference old Tauri output path" "old path found"
else
    ok "build-pkg.sh does NOT reference old Tauri output path"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9: build-pkg.sh — full run creates .pkg at correct version path
# ─────────────────────────────────────────────────────────────────────────────
section "9. build-pkg.sh — creates Blitz-{version}.pkg with correct content"

T4="$TMPROOT/pkg-full" && make_project "$T4" "3.1.4"
MOCK_BIN4="$T4/mock-bin" && make_mock_bin "$MOCK_BIN4"

# Pre-build a fake .app (as bundle.sh would produce)
mkdir -p "$T4/.build/Blitz.app/Contents/MacOS"
mkdir -p "$T4/.build/Blitz.app/Contents/Resources"
cat > "$T4/.build/Blitz.app/Contents/Info.plist" << 'XML'
<?xml version="1.0"?><plist version="1.0"><dict></dict></plist>
XML
printf '#!/bin/bash\necho blitz\n' > "$T4/.build/Blitz.app/Contents/MacOS/Blitz"
chmod +x "$T4/.build/Blitz.app/Contents/MacOS/Blitz"

# Override /usr/libexec/PlistBuddy to hit our mock
export PATH="$MOCK_BIN4:$PATH"
export PATH="$T4/mock-bin/../libexec:$PATH"

build_out=$(cd "$T4" && \
    PATH="$MOCK_BIN4:$PATH" \
    APPLE_SIGNING_IDENTITY="" \
    APPLE_INSTALLER_IDENTITY="" \
    bash scripts/build-pkg.sh 2>&1) && rc=0 || rc=$?

PKG_FILE="$T4/build/Blitz-3.1.4.pkg"
if [ $rc -eq 0 ] && [ -f "$PKG_FILE" ]; then
    ok "build-pkg.sh exits 0 and creates Blitz-3.1.4.pkg"
else
    fail "build-pkg.sh exits 0 and creates Blitz-3.1.4.pkg" \
         "exit=$rc, file_exists=$([ -f "$PKG_FILE" ] && echo yes || echo no); output: $(echo "$build_out" | tail -5)"
fi

# Check distribution.xml was generated with the right ID
DIST_XML="$T4/build/pkg/distribution.xml"
if [ -f "$DIST_XML" ]; then
    assert_file_contains "distribution.xml has com.blitz.macos" "com.blitz.macos" "$DIST_XML"
    assert_file_contains "distribution.xml has version 3.1.4"   "3.1.4"          "$DIST_XML"
else
    fail "distribution.xml was created" "not found: $DIST_XML"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10: deploy-pkg.sh — validation errors
# ─────────────────────────────────────────────────────────────────────────────
section "10. deploy-pkg.sh — validation: missing R2 credentials"

T5="$TMPROOT/deploy-no-creds" && make_project "$T5" "1.0.0"
# Create fake rclone so it passes the binary check
mkdir -p "$T5/node_modules/@repalash/rclone.js/bin"
cat > "$T5/node_modules/@repalash/rclone.js/bin/rclone" << 'SH'
#!/bin/bash
echo '{"version":"0.0.1"}'
exit 0
SH
chmod +x "$T5/node_modules/@repalash/rclone.js/bin/rclone"

out5=$(cd "$T5" && \
    unset CLOUDFLARE_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY 2>/dev/null || true; \
    bash scripts/deploy-pkg.sh 2>&1) && rc=0 || rc=$?
if [ $rc -ne 0 ]; then ok "deploy-pkg.sh exits non-zero when R2 creds missing"
else fail "deploy-pkg.sh exits non-zero when R2 creds missing" "exited 0"; fi

section "10b. deploy-pkg.sh — validation: missing .pkg file"

out5b=$(cd "$T5" && \
    CLOUDFLARE_ACCOUNT_ID=fake R2_ACCESS_KEY_ID=fake R2_SECRET_ACCESS_KEY=fake \
    bash scripts/deploy-pkg.sh 2>&1) && rc=0 || rc=$?
if [ $rc -ne 0 ]; then ok "deploy-pkg.sh exits non-zero when .pkg missing"
else fail "deploy-pkg.sh exits non-zero when .pkg missing" "exited 0"; fi
assert_contains "deploy-pkg.sh error mentions build:pkg" "build:pkg" "$out5b"

section "10c. deploy-pkg.sh — validation: missing CHANGELOG.md"

# Create a fake .pkg so it gets past the file check
mkdir -p "$T5/build"
dd if=/dev/zero of="$T5/build/Blitz-1.0.0.pkg" bs=1024 count=1 2>/dev/null

out5c=$(cd "$T5" && \
    CLOUDFLARE_ACCOUNT_ID=fake R2_ACCESS_KEY_ID=fake R2_SECRET_ACCESS_KEY=fake \
    bash scripts/deploy-pkg.sh 2>&1) && rc=0 || rc=$?
if [ $rc -ne 0 ]; then ok "deploy-pkg.sh exits non-zero when CHANGELOG.md missing"
else fail "deploy-pkg.sh exits non-zero when CHANGELOG.md missing" "exited 0"; fi
assert_contains "deploy-pkg.sh error mentions CHANGELOG" "CHANGELOG" "$out5c"

section "10d. deploy-pkg.sh — validation: version not in CHANGELOG.md"

# Write a CHANGELOG that doesn't have the current version
cat > "$T5/CHANGELOG.md" << 'MD'
# Changelog
## 0.9.9
- old version
MD

out5d=$(cd "$T5" && \
    CLOUDFLARE_ACCOUNT_ID=fake R2_ACCESS_KEY_ID=fake R2_SECRET_ACCESS_KEY=fake \
    bash scripts/deploy-pkg.sh 2>&1) && rc=0 || rc=$?
if [ $rc -ne 0 ]; then ok "deploy-pkg.sh exits non-zero when version not in CHANGELOG"
else fail "deploy-pkg.sh exits non-zero when version not in CHANGELOG" "exited 0"; fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11: deploy-pkg.sh — reads version from package.json
# ─────────────────────────────────────────────────────────────────────────────
section "11. deploy-pkg.sh — reads version from package.json (not tauri.conf.json)"

assert_file_contains "deploy-pkg.sh reads from package.json" \
    "package.json" "$ROOT_DIR/scripts/deploy-pkg.sh"

if grep -q "tauri.conf.json" "$ROOT_DIR/scripts/deploy-pkg.sh" 2>/dev/null; then
    fail "deploy-pkg.sh does NOT reference tauri.conf.json" "old tauri reference found"
else
    ok "deploy-pkg.sh does NOT reference tauri.conf.json"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 12: build-server.mjs — exits when SERVER_SRC_DIR doesn't exist
# ─────────────────────────────────────────────────────────────────────────────
section "12. build-server.mjs — exits non-zero when server source not found"

T6="$TMPROOT/server-no-src"
make_project "$T6" "1.0.0"
out6=$(cd "$T6" && \
    SERVER_SRC_DIR="/tmp/nonexistent-path-$$" \
    node scripts/build-server.mjs 2>&1) && rc=0 || rc=$?
if [ $rc -ne 0 ]; then ok "build-server.mjs exits non-zero when SERVER_SRC_DIR missing"
else fail "build-server.mjs exits non-zero when SERVER_SRC_DIR missing" "exited 0"; fi
assert_contains "build-server.mjs error mentions SERVER_SRC_DIR" "SERVER_SRC_DIR" "$out6"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 13: Entitlements.plist
# ─────────────────────────────────────────────────────────────────────────────
section "13. scripts/Entitlements.plist — content"

ENTS="$ROOT_DIR/scripts/Entitlements.plist"

# Valid plist
if plutil -lint "$ENTS" >/dev/null 2>&1; then ok "Entitlements.plist is valid XML/plist"
else fail "Entitlements.plist is valid XML/plist" "plutil -lint failed"; fi

assert_file_contains "sandbox disabled"                   "app-sandbox"                              "$ENTS"
assert_file_contains "JIT / unsigned memory allowed"      "allow-unsigned-executable-memory"         "$ENTS"
assert_file_contains "library validation disabled"        "disable-library-validation"               "$ENTS"
assert_file_contains "camera entitlement present"         "com.apple.security.device.camera"         "$ENTS"

# Verify sandbox is explicitly false — PlistBuddy handles dotted keys correctly
sandbox_val=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENTS" 2>/dev/null || echo "")
assert_eq "app-sandbox is false" "false" "$sandbox_val"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 14: preinstall — syntax and bundle ID
# ─────────────────────────────────────────────────────────────────────────────
section "14. scripts/pkg-scripts/preinstall — syntax and bundle ID"

PRE="$ROOT_DIR/scripts/pkg-scripts/preinstall"

if bash -n "$PRE" 2>/dev/null; then ok "preinstall has valid bash syntax"
else fail "preinstall has valid bash syntax" "bash -n failed"; fi

assert_file_contains "preinstall TCC resets com.blitz.macos" "com.blitz.macos" "$PRE"

if grep -q "dev.blitz.mac" "$PRE" 2>/dev/null; then
    fail "preinstall does NOT contain old dev.blitz.mac" "old bundle ID found"
else
    ok "preinstall does NOT contain old dev.blitz.mac"
fi

# Should check for screen capture + accessibility
assert_file_contains "preinstall resets ScreenCapture TCC" "ScreenCapture" "$PRE"
assert_file_contains "preinstall resets Accessibility TCC" "Accessibility"  "$PRE"

# Should check for Xcode
assert_file_contains "preinstall checks for Xcode"           "Xcode"       "$PRE"

# Should check iOS Simulator runtime
assert_file_contains "preinstall checks iOS Simulator runtime" "SimRuntime" "$PRE"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 15: postinstall — syntax and key behaviors
# ─────────────────────────────────────────────────────────────────────────────
section "15. scripts/pkg-scripts/postinstall — syntax and key behaviors"

POST="$ROOT_DIR/scripts/pkg-scripts/postinstall"

if bash -n "$POST" 2>/dev/null; then ok "postinstall has valid bash syntax"
else fail "postinstall has valid bash syntax" "bash -n failed"; fi

# Node.js installed to ~/.blitz/node-runtime
assert_file_contains "postinstall installs Node to ~/.blitz/node-runtime"  "node-runtime"     "$POST"
assert_file_contains "postinstall installs Ruby via rv"                    "ruby install"     "$POST"
assert_file_contains "postinstall installs CocoaPods"                      "cocoapods"        "$POST"
assert_file_contains "postinstall installs Python + idb"                   "fb-idb"           "$POST"
assert_file_contains "postinstall installs Claude Code CLI"                "claude-code"      "$POST"
assert_file_contains "postinstall clones WebDriverAgent"                   "WebDriverAgent"   "$POST"
assert_file_contains "postinstall launches Blitz.app"                      "open /Applications/Blitz.app" "$POST"

# Server deps dir path is correct for blitz-macos .app structure
assert_file_contains "postinstall references dist/server in .app Resources" \
    "dist/server" "$POST"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 16: NodeSidecarService.swift — ~/.blitz/node-runtime path added
# ─────────────────────────────────────────────────────────────────────────────
section "16. NodeSidecarService.swift — ~/.blitz/node-runtime search path"

SIDECAR_SWIFT="$ROOT_DIR/src/Services/NodeSidecarService.swift"

assert_file_contains "node-runtime path present in candidates" \
    "node-runtime/bin/node" "$SIDECAR_SWIFT"

# Verify order: node-runtime must come before /usr/local/bin/node
node_runtime_line=$(grep -n "node-runtime" "$SIDECAR_SWIFT" | head -1 | cut -d: -f1)
usr_local_line=$(grep -n '"/usr/local/bin/node"' "$SIDECAR_SWIFT" | head -1 | cut -d: -f1)

if [ -n "$node_runtime_line" ] && [ -n "$usr_local_line" ] && \
   [ "$node_runtime_line" -lt "$usr_local_line" ]; then
    ok "~/.blitz/node-runtime checked before /usr/local/bin/node"
else
    fail "~/.blitz/node-runtime checked before /usr/local/bin/node" \
         "node-runtime line=$node_runtime_line, usr/local line=$usr_local_line"
fi

# Verify it uses homeDirectoryForCurrentUser (not hardcoded ~)
assert_file_contains "uses homeDirectoryForCurrentUser (not hardcoded ~)" \
    "homeDirectoryForCurrentUser" "$SIDECAR_SWIFT"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 17: CHANGELOG.md exists and has a valid entry
# ─────────────────────────────────────────────────────────────────────────────
section "17. CHANGELOG.md — exists and has entry for current version"

CHANGELOG="$ROOT_DIR/CHANGELOG.md"
if [ -f "$CHANGELOG" ]; then ok "CHANGELOG.md exists"
else fail "CHANGELOG.md exists" "file not found"; fi

CURRENT_VER=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('$ROOT_DIR/package.json','utf8')).version)" 2>/dev/null \
  || grep '"version"' "$ROOT_DIR/package.json" | head -1 | sed 's/.*: *"\(.*\)".*/\1/')

if grep -q "## $CURRENT_VER" "$CHANGELOG" 2>/dev/null; then
    ok "CHANGELOG.md has entry for v$CURRENT_VER"
else
    fail "CHANGELOG.md has entry for v$CURRENT_VER" \
         "no '## $CURRENT_VER' section found"
fi

# Has at least one non-empty bullet point under the version
notes=$(sed -n "/^## $CURRENT_VER/,/^## /{/^## $CURRENT_VER/d;/^## /d;p;}" "$CHANGELOG" \
    | grep -v '^[[:space:]]*$' | head -1)
if [ -n "$notes" ]; then ok "CHANGELOG.md has non-empty release notes for v$CURRENT_VER"
else fail "CHANGELOG.md has non-empty release notes" "no content found under ## $CURRENT_VER"; fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 18: Scripts are executable
# ─────────────────────────────────────────────────────────────────────────────
section "18. All scripts are executable"

for f in \
    "$ROOT_DIR/scripts/bundle.sh" \
    "$ROOT_DIR/scripts/build-pkg.sh" \
    "$ROOT_DIR/scripts/deploy-pkg.sh" \
    "$ROOT_DIR/scripts/pkg-scripts/preinstall" \
    "$ROOT_DIR/scripts/pkg-scripts/postinstall"; do
    if [ -x "$f" ]; then ok "$(basename $f) is executable"
    else fail "$(basename $f) is executable" "chmod +x needed on $f"; fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "${BOLD}Results: ${GREEN}$PASS passed${RESET}, ${RED}$FAIL failed${RESET} (of $TOTAL)"
    echo ""
    echo -e "${RED}Failed tests:${RESET}"
    for e in "${ERRORS[@]}"; do
        echo -e "  ${RED}✗${RESET} $e"
    done
fi
echo "────────────────────────────────────────"

exit $FAIL
