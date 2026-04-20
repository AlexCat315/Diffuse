#!/bin/bash
# Downloads wgpu-native prebuilt dylib for macOS into vendor/wgpu/.
# Run this once before `swift build`.
#
# Usage: ./scripts/fetch-wgpu.sh

set -euo pipefail

VERSION="v29.0.0.0"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/wgpu"
rm -rf "$VENDOR"
mkdir -p "$VENDOR"

# v29 release asset naming: wgpu-macos-${arch}-release.zip
URL="https://github.com/gfx-rs/wgpu-native/releases/download/${VERSION}/wgpu-macos-${TRIPLE/-apple-darwin/}-release.zip"
ZIP="$VENDOR/wgpu.zip"

echo "Downloading $URL"
curl -fL -o "$ZIP" "$URL"

unzip -o "$ZIP" -d "$VENDOR" >/dev/null
rm -f "$ZIP"

ls -la "$VENDOR"/lib* 2>/dev/null || ls -la "$VENDOR"
echo "wgpu-native ${VERSION} installed at $VENDOR"
