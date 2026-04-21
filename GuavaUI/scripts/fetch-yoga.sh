#!/usr/bin/env bash
set -euo pipefail

YOGA_VERSION="3.2.1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/../vendor/yoga"

echo "==> Fetching Yoga ${YOGA_VERSION}..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "https://github.com/facebook/yoga/archive/refs/tags/v${YOGA_VERSION}.tar.gz" \
    | tar -xz -C "$TMP"
SRC="$TMP/yoga-${YOGA_VERSION}"

echo "==> Configuring cmake..."
BUILD="$TMP/build"
cmake -S "$SRC" -B "$BUILD" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DYOGA_BUILD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    2>&1

echo "==> Building..."
cmake --build "$BUILD" --config Release 2>&1

echo "==> Copying artifacts..."
mkdir -p "$VENDOR_DIR/include/yoga" "$VENDOR_DIR/lib"

# Find and copy the static library (name varies: yoga / yogacore)
LIB=$(find "$BUILD" -name "libyoga*.a" -o -name "libyogacore*.a" 2>/dev/null | head -1)
if [ -z "$LIB" ]; then
    echo "ERROR: Could not find libyoga*.a in build directory."
    find "$BUILD" -name "*.a" | head -10
    exit 1
fi
cp "$LIB" "$VENDOR_DIR/lib/libyoga.a"

# Copy public C headers
cp "$SRC/yoga/"*.h "$VENDOR_DIR/include/yoga/"

echo ""
echo "==> Done. Artifacts:"
echo "    lib: $VENDOR_DIR/lib/libyoga.a ($(du -sh "$VENDOR_DIR/lib/libyoga.a" | cut -f1))"
echo "    headers: $(ls "$VENDOR_DIR/include/yoga/")"
