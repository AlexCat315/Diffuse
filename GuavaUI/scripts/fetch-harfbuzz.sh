#!/usr/bin/env bash
set -euo pipefail

HARFBUZZ_VERSION="10.4.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/../vendor/harfbuzz"
FREETYPE_PREFIX="$SCRIPT_DIR/../vendor/freetype"

if [ ! -f "$FREETYPE_PREFIX/lib/libfreetype.a" ]; then
    echo "ERROR: FreeType not found. Run fetch-freetype.sh first."
    exit 1
fi

echo "==> Fetching HarfBuzz ${HARFBUZZ_VERSION}..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" \
    | tar -xJ -C "$TMP"
SRC="$TMP/harfbuzz-${HARFBUZZ_VERSION}"

echo "==> Configuring cmake (minimal: FreeType + CoreText only)..."
BUILD="$TMP/build"
cmake -S "$SRC" -B "$BUILD" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DHB_HAVE_FREETYPE=ON \
    -DHB_HAVE_CORETEXT=ON \
    -DHB_HAVE_GLIB=OFF \
    -DHB_HAVE_GOBJECT=OFF \
    -DHB_HAVE_ICU=OFF \
    -DHB_HAVE_GRAPHITE2=OFF \
    -DHB_HAVE_CAIRO=OFF \
    -DCMAKE_PREFIX_PATH="$FREETYPE_PREFIX" \
    -DFREETYPE_INCLUDE_DIRS="$FREETYPE_PREFIX/include" \
    -DFREETYPE_LIBRARY="$FREETYPE_PREFIX/lib/libfreetype.a" \
    2>&1

echo "==> Building..."
cmake --build "$BUILD" --config Release 2>&1

echo "==> Copying artifacts..."
mkdir -p "$VENDOR_DIR/include" "$VENDOR_DIR/lib"

LIB=$(find "$BUILD" -name "libharfbuzz.a" 2>/dev/null | head -1)
if [ -z "$LIB" ]; then
    echo "ERROR: Could not find libharfbuzz.a in build directory."
    find "$BUILD" -name "*.a" | head -10
    exit 1
fi
cp "$LIB" "$VENDOR_DIR/lib/libharfbuzz.a"

# Copy public C headers (only the ones needed)
for h in hb.h hb-blob.h hb-buffer.h hb-common.h hb-deprecated.h hb-draw.h \
         hb-face.h hb-features.h hb-font.h hb-ft.h hb-map.h hb-paint.h \
         hb-set.h hb-shape.h hb-shape-plan.h hb-style.h hb-unicode.h \
         hb-version.h hb-ot.h hb-ot-color.h hb-ot-font.h hb-ot-layout.h \
         hb-ot-math.h hb-ot-meta.h hb-ot-metrics.h hb-ot-name.h \
         hb-ot-shape.h hb-ot-var.h hb-coretext.h; do
    [ -f "$SRC/src/$h" ] && cp "$SRC/src/$h" "$VENDOR_DIR/include/"
done

# hb-version.h is generated during build
[ -f "$BUILD/src/hb-version.h" ] && cp "$BUILD/src/hb-version.h" "$VENDOR_DIR/include/"

echo ""
echo "==> Done. Artifacts:"
echo "    lib: $VENDOR_DIR/lib/libharfbuzz.a ($(du -sh "$VENDOR_DIR/lib/libharfbuzz.a" | cut -f1))"
echo "    headers: $(ls "$VENDOR_DIR/include/")"
