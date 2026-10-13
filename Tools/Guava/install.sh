#!/bin/sh
set -eu
GUAVA_TOOLS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUAVA_PREFIX=${1:-"$HOME/.local"}
GUAVA_SWIFT=${GUAVA_SWIFT_EXECUTABLE:-swift}
if ! command -v "$GUAVA_SWIFT" >/dev/null 2>&1; then
  echo 'Swift 6.4.1 is required to build this source CLI. Install it from https://www.swift.org/install/.' >&2
  echo 'macOS/Linux with Swiftly: swiftly install 6.4.1; swiftly use 6.4.1. Then rerun this installer.' >&2
  exit 1
fi
"$GUAVA_SWIFT" build --package-path "$GUAVA_TOOLS" --configuration release --product guava
GUAVA_BIN=$("$GUAVA_SWIFT" build --package-path "$GUAVA_TOOLS" --configuration release --show-bin-path)
exec "$GUAVA_SWIFT" "$GUAVA_TOOLS/install.swift" "$GUAVA_BIN" "$GUAVA_PREFIX"
