#!/bin/sh
set -eu
GUAVA_TOOLS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUAVA_PREFIX=${1:-"$HOME/.local"}
GUAVA_SWIFT=${GUAVA_SWIFT_EXECUTABLE:-swift}
"$GUAVA_SWIFT" build --package-path "$GUAVA_TOOLS" --configuration release --product guava
GUAVA_BIN=$("$GUAVA_SWIFT" build --package-path "$GUAVA_TOOLS" --configuration release --show-bin-path)
exec "$GUAVA_SWIFT" "$GUAVA_TOOLS/install.swift" "$GUAVA_BIN" "$GUAVA_PREFIX"
