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

# ── Step 0: Refresh the embedded cfg blob (single-file CLI) ──
# The CLI embeds the whole DDRTestFiles/ library via .incbin (Sources/CDDRBlob);
# regenerate it so the built binary carries the current cfgs. Deterministic, ~6s.
echo "=== Refreshing embedded cfg blob ==="
bash "$PROJECT_DIR/scripts/embed_cfgs.sh"

# ── Step 1: Produce ONE universal STATIC libusb ──
# libusb is linked STATICALLY, so the CLI ships as a single file (it already
# embeds the whole cfg library via .incbin) and the .app needs no Frameworks/
# dylib or rpath. Everything is linked against the SAME libusb, or the arm64
# slice would demand a compat version the x86_64 one doesn't have.
#
# NOTE (licensing): libusb is LGPL-2.1+. Static linking carries the obligation to
# let a recipient relink against their own libusb — ship this archive plus the
# license, or the source, with any external distribution.
LIBUSB_STAGE="$STAGING_DIR/libusb-static"
rm -rf "$LIBUSB_STAGE"
mkdir -p "$LIBUSB_STAGE"
LIBUSB_A="$LIBUSB_STAGE/libusb-1.0.a"

BREW_A="$LIBUSB_BREW/lib/libusb-1.0.a"
BREW_A_ARCHS="$(lipo -info "$BREW_A" 2>/dev/null || echo "")"
NEED_SOURCE_BUILD=0
for arch in "${ARCHES[@]}"; do
    case "$BREW_A_ARCHS" in *"$arch"*) ;; *) NEED_SOURCE_BUILD=1 ;; esac
done

if [ "$NEED_SOURCE_BUILD" = "0" ]; then
    echo "=== Homebrew libusb.a already covers ${ARCHES[*]} ==="
    cp "$BREW_A" "$LIBUSB_A"
else
    echo "=== Building static libusb from source (${ARCHES[*]}) ==="
    LIBUSB_BUILD="$STAGING_DIR/libusb-build"
    rm -rf "$LIBUSB_BUILD"
    mkdir -p "$LIBUSB_BUILD"
    curl -sL https://github.com/libusb/libusb/releases/download/v1.0.27/libusb-1.0.27.tar.bz2 \
        -o "$LIBUSB_BUILD/libusb.tar.bz2"
    tar xf "$LIBUSB_BUILD/libusb.tar.bz2" -C "$LIBUSB_BUILD"

    SLICES=()
    for arch in "${ARCHES[@]}"; do
        case "$arch" in
            arm64)  host=aarch64-apple-darwin ;;
            x86_64) host=x86_64-apple-darwin ;;
            *) echo "Unsupported arch: $arch"; exit 1 ;;
        esac
        echo "--- libusb $arch (static) ---"
        mkdir -p "$LIBUSB_BUILD/build-$arch" && cd "$LIBUSB_BUILD/build-$arch"
        "$LIBUSB_BUILD/libusb-1.0.27/configure" \
            --host="$host" \
            --enable-static=yes \
            --enable-shared=no \
            --prefix="$LIBUSB_BUILD/install-$arch" \
            CFLAGS="-arch $arch -mmacosx-version-min=12.0" \
            LDFLAGS="-arch $arch -mmacosx-version-min=12.0" >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null
        SLICES+=("$LIBUSB_BUILD/install-$arch/lib/libusb-1.0.a")
    done
    cd "$PROJECT_DIR"

    if [ ${#SLICES[@]} -gt 1 ]; then
        echo "--- Merging libusb.a universal ---"
        lipo -create "${SLICES[@]}" -output "$LIBUSB_A"
    else
        cp "${SLICES[0]}" "$LIBUSB_A"
    fi
fi
echo "libusb.a: $(lipo -info "$LIBUSB_A")"

# pkg-config supplies ONLY the header path. The archive and libusb's own macOS
# dependencies go in as -Xlinker flags below, because SwiftPM's pkg-config
# handling does not pass `-framework` through.
LIBUSB_PKG_DIR="$STAGING_DIR/libusb-pkg"
rm -rf "$LIBUSB_PKG_DIR"; mkdir -p "$LIBUSB_PKG_DIR"
cat > "$LIBUSB_PKG_DIR/libusb-1.0.pc" << PCEOF
prefix=$LIBUSB_BREW
includedir=\${prefix}/include
Name: libusb-1.0
Description: libusb (static, linked via -Xlinker)
Version: 1.0.27
Libs:
Cflags: -I\${includedir}/libusb-1.0
PCEOF

# libusb's Libs.private on macOS — required once it is linked statically.
LIBUSB_LINK=(-Xlinker "$LIBUSB_A"
             -Xlinker -lobjc
             -Xlinker -framework -Xlinker IOKit
             -Xlinker -framework -Xlinker CoreFoundation
             -Xlinker -framework -Xlinker Security)

# ── Step 2: Build Swift executables (every arch links the static libusb) ──
echo "=== Building release (${ARCHES[*]}) ==="
for arch in "${ARCHES[@]}"; do
    echo "--- Building for $arch ---"
    PKG_CONFIG_PATH="$LIBUSB_PKG_DIR" swift build -c release --arch "$arch" "${LIBUSB_LINK[@]}"
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

# (No step 6: libusb is inside the executables now — no Frameworks/, no rpath.)

# ── Step 7: Verify ──

echo "=== Verifying bundle ==="
echo "Architectures:"
lipo -info "$BUNDLE_DIR/Contents/MacOS/RockchipDDRTestUtility"
lipo -info "$BUNDLE_DIR/Contents/MacOS/RockchipDDRTestUtilityCLI"

# Nothing may reference libusb dynamically any more. A leftover reference means
# the static archive was not picked up and the binary would die on a machine
# without Homebrew — the exact failure this change removes.
assert_no_dynamic_libusb() {
    local bin="$1" refs
    refs="$(otool -L "$bin" | grep -i libusb || true)"
    if [ -n "$refs" ]; then
        echo "ERROR: $(basename "$bin") still links libusb dynamically:"
        echo "$refs"
        exit 1
    fi
}
for exe in RockchipDDRTestUtility RockchipDDRTestUtilityCLI; do
    assert_no_dynamic_libusb "$BUNDLE_DIR/Contents/MacOS/$exe"
done
echo "libusb: statically linked (no dynamic reference)"

# ── Step 7.5: Assemble standalone CLI distribution ──
# The CLI ships as ONE file: it embeds the whole cfg library (Sources/CDDRBlob)
# and links libusb statically, so there is no DDRTestFiles/ to place, no sibling
# dylib and no rpath. arm64+x86_64, macOS 12+, no Homebrew on the target machine.
echo "=== Packaging standalone CLI ==="
CLI_DIST="$STAGING_DIR/cli"
CLI_TARBALL="$PROJECT_DIR/RockchipDDRTestUtilityCLI-macos.tar.gz"
rm -rf "$CLI_DIST"
mkdir -p "$CLI_DIST"
CLI_BIN="RockchipDDRTestUtilityCLI"
cp "$BUILD_DIR/RockchipDDRTestUtilityCLI" "$CLI_DIST/$CLI_BIN"
chmod u+w "$CLI_DIST/$CLI_BIN"
assert_no_dynamic_libusb "$CLI_DIST/$CLI_BIN"

echo "CLI arch:"; lipo -info "$CLI_DIST/$CLI_BIN"

# Ad-hoc codesign — lipo (fat binary) invalidates the linker's per-slice ad-hoc
# signature, and on Apple Silicon a binary with a broken signature is killed at
# launch (SIGKILL). One file to sign now.
echo "=== Ad-hoc codesigning CLI ==="
codesign --force --sign - "$CLI_DIST/$CLI_BIN"
codesign --verify --verbose "$CLI_DIST/$CLI_BIN"

tar -czf "$CLI_TARBALL" -C "$CLI_DIST" "$CLI_BIN"
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
