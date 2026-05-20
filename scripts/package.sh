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

# ── Step 1: Build universal libusb if needed ──

if [ ${#ARCHES[@]} -gt 1 ]; then
    LIBUSB_ARCHS=$(lipo -info "$LIBUSB_DYLIB" 2>/dev/null || echo "")
    if echo "$LIBUSB_ARCHS" | grep -q "x86_64.*arm64\|arm64.*x86_64"; then
        echo "=== libusb is already universal ==="
        UNIVERSAL_LIBUSB="$LIBUSB_DYLIB"
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
        UNIVERSAL_LIBUSB="$STAGING_DIR/libusb-1.0.0.dylib"
        lipo -create \
            "$LIBUSB_BUILD/install-arm64/lib/libusb-1.0.0.dylib" \
            "$LIBUSB_BUILD/install-x86_64/lib/libusb-1.0.0.dylib" \
            -output "$UNIVERSAL_LIBUSB"

        cd "$PROJECT_DIR"
    fi
else
    UNIVERSAL_LIBUSB="$LIBUSB_DYLIB"
fi

# ── Step 2: Build Swift executables ──

echo "=== Building release (${ARCHES[*]}) ==="

for arch in "${ARCHES[@]}"; do
    echo "--- Building for $arch ---"

    if [ "$arch" = "x86_64" ] && [ "$HOST_ARCH" = "arm64" ]; then
        # Cross-compile x86_64: link against universal libusb dylib directly
        LIBUSB_LINK_DIR="$STAGING_DIR/libusb-link-x86_64"
        mkdir -p "$LIBUSB_LINK_DIR"
        cp "$UNIVERSAL_LIBUSB" "$LIBUSB_LINK_DIR/libusb-1.0.0.dylib"
        ln -sf libusb-1.0.0.dylib "$LIBUSB_LINK_DIR/libusb-1.0.dylib"

        # Override pkg-config to point to universal libusb
        LIBUSB_PKG_DIR="$STAGING_DIR/libusb-pkg-x86_64"
        mkdir -p "$LIBUSB_PKG_DIR"
        cat > "$LIBUSB_PKG_DIR/libusb-1.0.pc" << PCEOF
prefix=$LIBUSB_LINK_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}
includedir=$LIBUSB_BREW/include
Name: libusb-1.0
Description: libusb
Version: 1.0.27
Libs: -L\${libdir} -lusb-1.0
Cflags: -I\${includedir}/libusb-1.0
PCEOF

        PKG_CONFIG_PATH="$LIBUSB_PKG_DIR" \
        swift build -c release --arch "$arch"
    else
        swift build -c release --arch "$arch"
    fi
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

# ── Step 6: Bundle libusb ──

echo "=== Bundling libusb ==="
cp "$UNIVERSAL_LIBUSB" "$BUNDLE_DIR/Contents/Frameworks/libusb-1.0.0.dylib"

install_name_tool -id "@rpath/libusb-1.0.0.dylib" \
    "$BUNDLE_DIR/Contents/Frameworks/libusb-1.0.0.dylib"

for exe in RockchipDDRTestUtility RockchipDDRTestUtilityCLI; do
    # Rewrite both Homebrew paths (arm64 /opt/homebrew and Intel /usr/local)
    install_name_tool -change \
        /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib \
        @rpath/libusb-1.0.0.dylib \
        "$BUNDLE_DIR/Contents/MacOS/$exe"
    install_name_tool -change \
        /usr/local/opt/libusb/lib/libusb-1.0.0.dylib \
        @rpath/libusb-1.0.0.dylib \
        "$BUNDLE_DIR/Contents/MacOS/$exe"
    install_name_tool -add_rpath \
        @executable_path/../Frameworks \
        "$BUNDLE_DIR/Contents/MacOS/$exe"
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
