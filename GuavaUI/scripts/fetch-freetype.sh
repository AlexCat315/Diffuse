#!/usr/bin/env bash
set -euo pipefail

FREETYPE_VERSION="2.13.3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/../vendor/freetype"

echo "==> Fetching FreeType ${FREETYPE_VERSION}..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz" \
    | tar -xJ -C "$TMP"
SRC="$TMP/freetype-${FREETYPE_VERSION}"

echo "==> Configuring cmake..."
BUILD="$TMP/build"
cmake -S "$SRC" -B "$BUILD" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFT_DISABLE_BZIP2=TRUE \
    -DFT_DISABLE_BROTLI=TRUE \
    -DFT_DISABLE_PNG=TRUE \
    -DFT_DISABLE_HARFBUZZ=TRUE \
    -DFT_DISABLE_ZLIB=FALSE \
    2>&1

echo "==> Building..."
cmake --build "$BUILD" --config Release 2>&1

echo "==> Copying artifacts..."
mkdir -p "$VENDOR_DIR/include" "$VENDOR_DIR/lib"

LIB=$(find "$BUILD" -name "libfreetype*.a" 2>/dev/null | head -1)
if [ -z "$LIB" ]; then
    echo "ERROR: Could not find libfreetype*.a in build directory."
    find "$BUILD" -name "*.a" | head -10
    exit 1
fi
cp "$LIB" "$VENDOR_DIR/lib/libfreetype.a"

# Copy public headers (ft2build.h + freetype/*.h)
cp "$SRC/include/ft2build.h" "$VENDOR_DIR/include/"
cp -R "$SRC/include/freetype" "$VENDOR_DIR/include/"

echo ""
echo "==> Done. Artifacts:"
echo "    lib: $VENDOR_DIR/lib/libfreetype.a ($(du -sh "$VENDOR_DIR/lib/libfreetype.a" | cut -f1))"
echo "    headers: $(ls "$VENDOR_DIR/include/")"
