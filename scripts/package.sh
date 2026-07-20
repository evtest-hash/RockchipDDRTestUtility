#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_NAME="Rockchip DDR Test Utility.app"
STAGING_DIR="$PROJECT_DIR/.staging"
BUNDLE_DIR="$STAGING_DIR/$BUNDLE_NAME"
DMG_NAME="RockchipDDRTestUtility"
DMG_DIR="$STAGING_DIR/dmg"

# Detect host arch and decide which arches to build
HOST_ARCH="$(uname -m)"
if [ "${BUILD_UNIVERSAL:-1}" = "1" ] && [ "$HOST_ARCH" = "arm64" ]; then
    ARCHES=("arm64" "x86_64")
else
    ARCHES=("$HOST_ARCH")
fi

LIBUSB_BREW="$(brew --prefix libusb 2>/dev/null || echo /opt/homebrew/opt/libusb)"
LIBUSB_DYLIB="$LIBUSB_BREW/lib/libusb-1.0.0.dylib"
if [ ! -f "$LIBUSB_DYLIB" ]; then
    echo "Error: libusb not found. Run: brew install libusb"
    exit 1
fi

cd "$PROJECT_DIR"

# Fail the build if any slice of $1 references a libusb that is NOT relocatable
# (i.e. not an @rpath/@loader_path/@executable_path path). Catches leftover
# absolute Homebrew or build-staging paths that would break on a user's machine.
verify_libusb() {
    local bin="$1" arch bad
    for arch in "${ARCHES[@]}"; do
        bad="$(otool -arch "$arch" -L "$bin" 2>/dev/null \
                | awk '/libusb-1\.0\.0\.dylib/{print $1}' | grep -v '^@' || true)"
        if [ -n "$bad" ]; then
            echo "ERROR: $(basename "$bin") ($arch) references non-relocatable libusb:"
            echo "  $bad"
            exit 1
        fi
    done
}

# Add an LC_RPATH only if absent — `swift build` already stamps @loader_path onto
# executables (for the Swift runtime), so a blind -add_rpath would error out.
add_rpath_once() {
    local bin="$1" rp="$2"
    if ! otool -l "$bin" | grep -qF "path $rp "; then
        install_name_tool -add_rpath "$rp" "$bin"
    fi
}

# ── Step 0: Refresh the embedded cfg blob (single-file CLI) ──
# The CLI embeds the whole DDRTestFiles/ library via .incbin (Sources/CDDRBlob);
# regenerate it so the built binary carries the current cfgs. Deterministic, ~6s.
echo "=== Refreshing embedded cfg blob ==="
bash "$PROJECT_DIR/scripts/embed_cfgs.sh"

# ── Step 1: Produce ONE staged libusb that every slice links against ──
# Both executables, both arches, AND the bundled copy must be the SAME libusb, or
# the arm64 slice (linked against a newer Homebrew libusb) demands a compat
# version the bundled dylib can't satisfy → dyld rejects it at launch. We stage a
# single universal dylib with install_name @rpath/libusb-1.0.0.dylib and point a
# pkg-config override at it for ALL arch builds; consumers add the right rpath.

if [ ${#ARCHES[@]} -gt 1 ]; then
    LIBUSB_ARCHS=$(lipo -info "$LIBUSB_DYLIB" 2>/dev/null || echo "")
    if echo "$LIBUSB_ARCHS" | grep -q "x86_64.*arm64\|arm64.*x86_64"; then
        echo "=== Homebrew libusb is already universal ==="
        LIBUSB_SRC="$LIBUSB_DYLIB"
    else
        echo "=== Building universal libusb from source ==="
        LIBUSB_BUILD="$STAGING_DIR/libusb-build"
        rm -rf "$LIBUSB_BUILD"
        mkdir -p "$LIBUSB_BUILD"

        curl -sL https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2 \
            -o "$LIBUSB_BUILD/libusb.tar.bz2"
        tar xf "$LIBUSB_BUILD/libusb.tar.bz2" -C "$LIBUSB_BUILD"

        echo "--- libusb arm64 ---"
        mkdir -p "$LIBUSB_BUILD/build-arm64" && cd "$LIBUSB_BUILD/build-arm64"
        "$LIBUSB_BUILD/libusb-1.0.27/configure" \
            --host=aarch64-apple-darwin \
            --enable-static=no \
            --prefix="$LIBUSB_BUILD/install-arm64" \
            CFLAGS="-arch arm64 -mmacosx-version-min=12.0" \
            LDFLAGS="-arch arm64 -mmacosx-version-min=12.0"
        make -j"$(sysctl -n hw.ncpu)" && make install

        echo "--- libusb x86_64 ---"
        mkdir -p "$LIBUSB_BUILD/build-x86_64" && cd "$LIBUSB_BUILD/build-x86_64"
        "$LIBUSB_BUILD/libusb-1.0.27/configure" \
            --host=x86_64-apple-darwin \
            --enable-static=no \
            --prefix="$LIBUSB_BUILD/install-x86_64" \
            CFLAGS="-arch x86_64 -mmacosx-version-min=12.0" \
            LDFLAGS="-arch x86_64 -mmacosx-version-min=12.0"
        make -j"$(sysctl -n hw.ncpu)" && make install

        echo "--- Merging libusb universal ---"
        LIBUSB_SRC="$STAGING_DIR/libusb-src.dylib"
        lipo -create \
            "$LIBUSB_BUILD/install-arm64/lib/libusb-1.0.0.dylib" \
            "$LIBUSB_BUILD/install-x86_64/lib/libusb-1.0.0.dylib" \
            -output "$LIBUSB_SRC"

        cd "$PROJECT_DIR"
    fi
else
    LIBUSB_SRC="$LIBUSB_DYLIB"
fi

# Stage the canonical libusb: install_name @rpath, plus the -lusb-1.0 link name.
LIBUSB_STAGE="$STAGING_DIR/libusb-universal"
rm -rf "$LIBUSB_STAGE"
mkdir -p "$LIBUSB_STAGE"
UNIVERSAL_LIBUSB="$LIBUSB_STAGE/libusb-1.0.0.dylib"
cp "$LIBUSB_SRC" "$UNIVERSAL_LIBUSB"
chmod u+w "$UNIVERSAL_LIBUSB"
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$UNIVERSAL_LIBUSB"
ln -sf libusb-1.0.0.dylib "$LIBUSB_STAGE/libusb-1.0.dylib"

# One pkg-config override, used for EVERY arch build.
LIBUSB_PKG_DIR="$STAGING_DIR/libusb-pkg"
mkdir -p "$LIBUSB_PKG_DIR"
cat > "$LIBUSB_PKG_DIR/libusb-1.0.pc" << PCEOF
prefix=$LIBUSB_STAGE
exec_prefix=\${prefix}
libdir=\${exec_prefix}
includedir=$LIBUSB_BREW/include
Name: libusb-1.0
Description: libusb
Version: 1.0.27
Libs: -L\${libdir} -lusb-1.0
Cflags: -I\${includedir}/libusb-1.0
PCEOF

# ── Step 2: Build Swift executables (all arches link the staged libusb) ──

echo "=== Building release (${ARCHES[*]}) ==="
for arch in "${ARCHES[@]}"; do
    echo "--- Building for $arch ---"
    PKG_CONFIG_PATH="$LIBUSB_PKG_DIR" swift build -c release --arch "$arch"
done

# ── Step 3: Create fat binaries ──

if [ ${#ARCHES[@]} -gt 1 ]; then
    echo "=== Creating universal binaries ==="
    mkdir -p "$PROJECT_DIR/.build/universal"
    for exe in RockchipDDRTestUtility RockchipDDRTestUtilityCLI; do
        lipo -create \
            "$PROJECT_DIR/.build/arm64-apple-macosx/release/$exe" \
            "$PROJECT_DIR/.build/x86_64-apple-macosx/release/$exe" \
            -output "$PROJECT_DIR/.build/universal/$exe"
    done
    BUILD_DIR="$PROJECT_DIR/.build/universal"
else
    BUILD_DIR="$PROJECT_DIR/.build/release"
fi

# ── Step 4: Assemble .app bundle ──

echo "=== Assembling .app bundle ==="
rm -rf "$STAGING_DIR/$BUNDLE_NAME"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Frameworks"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BUILD_DIR/RockchipDDRTestUtility" "$BUNDLE_DIR/Contents/MacOS/"
cp "$BUILD_DIR/RockchipDDRTestUtilityCLI" "$BUNDLE_DIR/Contents/MacOS/"

cp "$PROJECT_DIR/scripts/Info.plist" "$BUNDLE_DIR/Contents/"
printf "APPL????" > "$BUNDLE_DIR/Contents/PkgInfo"

if [ -f "$PROJECT_DIR/scripts/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/scripts/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
fi

# ── Step 5: Bundle DDR test files ──

echo "=== Copying DDRTestFiles ==="
if [ -d "$PROJECT_DIR/DDRTestFiles" ]; then
    cp -R "$PROJECT_DIR/DDRTestFiles" "$BUNDLE_DIR/Contents/Resources/DDRTestFiles"
    find "$BUNDLE_DIR/Contents/Resources/DDRTestFiles" \( -name '.DS_Store' -o -name '*.exe' \) -delete
else
    echo "WARNING: DDRTestFiles directory not found"
fi

# ── Step 6: Bundle libusb into the .app ──
# Every slice already references @rpath/libusb-1.0.0.dylib (Step 1/2), so we only
# drop the dylib in Frameworks and add the rpath. No per-path -change needed.

echo "=== Bundling libusb (.app) ==="
cp "$UNIVERSAL_LIBUSB" "$BUNDLE_DIR/Contents/Frameworks/libusb-1.0.0.dylib"

for exe in RockchipDDRTestUtility RockchipDDRTestUtilityCLI; do
    add_rpath_once "$BUNDLE_DIR/Contents/MacOS/$exe" "@executable_path/../Frameworks"
    verify_libusb "$BUNDLE_DIR/Contents/MacOS/$exe"
done

# ── Step 7: Verify ──

echo "=== Verifying bundle ==="
echo "Architectures:"
lipo -info "$BUNDLE_DIR/Contents/MacOS/RockchipDDRTestUtility"
lipo -info "$BUNDLE_DIR/Contents/Frameworks/libusb-1.0.0.dylib"
echo "Dynamic libraries:"
otool -L "$BUNDLE_DIR/Contents/MacOS/RockchipDDRTestUtility" | grep -E "libusb|rpath"
echo "Rpaths:"
otool -l "$BUNDLE_DIR/Contents/MacOS/RockchipDDRTestUtility" | grep -A2 LC_RPATH

# ── Step 7.5: Assemble standalone CLI distribution ──
# The CLI ships as a self-contained tarball (binary + a sibling libusb dylib),
# NOT the .app: it embeds the whole cfg library (Sources/CDDRBlob), so it needs
# no DDRTestFiles/. Every slice references @rpath/libusb-1.0.0.dylib; adding an
# @loader_path rpath makes that resolve to the sibling dylib. Same universal
# libusb as the GUI → identical OS compatibility (arm64+x86_64, macOS 12+, no brew).
echo "=== Packaging standalone CLI ==="
CLI_DIST="$STAGING_DIR/cli"
CLI_TARBALL="$PROJECT_DIR/RockchipDDRTestUtilityCLI-macos.tar.gz"
rm -rf "$CLI_DIST"
mkdir -p "$CLI_DIST"
cp "$BUILD_DIR/RockchipDDRTestUtilityCLI" "$CLI_DIST/ddrtest"
cp "$UNIVERSAL_LIBUSB" "$CLI_DIST/libusb-1.0.0.dylib"
chmod u+w "$CLI_DIST/ddrtest" "$CLI_DIST/libusb-1.0.0.dylib"

add_rpath_once "$CLI_DIST/ddrtest" "@loader_path"
verify_libusb "$CLI_DIST/ddrtest"

echo "CLI arch:"; lipo -info "$CLI_DIST/ddrtest"
echo "CLI libusb + rpath:"; otool -L "$CLI_DIST/ddrtest" | grep -E "libusb"; otool -l "$CLI_DIST/ddrtest" | grep -A2 LC_RPATH

tar -czf "$CLI_TARBALL" -C "$CLI_DIST" ddrtest libusb-1.0.0.dylib
echo "=== CLI tarball: $CLI_TARBALL ($(du -sh "$CLI_TARBALL" | cut -f1)) ==="

# ── Step 8: Create DMG ──

echo "=== Creating DMG ==="
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$BUNDLE_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create \
    -volname "$DMG_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$PROJECT_DIR/$DMG_NAME.dmg"

SIZE=$(du -sh "$PROJECT_DIR/$DMG_NAME.dmg" | cut -f1)
echo ""
echo "=== Done: $PROJECT_DIR/$DMG_NAME.dmg ($SIZE) ==="
