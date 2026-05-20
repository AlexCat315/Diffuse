#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# ── bootstrap: compile C/C++ native deps via SPM plugin ─────────────────────
if [ "$#" -gt 0 ] && [ "$1" = "bootstrap" ]; then
    shift
    export MIMALLOC_DISABLE_REDIRECT=1
    swift package --package-path "$ROOT/Engine" \
        --allow-writing-to-package-directory build-native-deps "$@"
    swift package --package-path "$ROOT/GuavaUI" \
        --allow-writing-to-package-directory build-native-deps "$@"
    exit 0
fi

# ── swift build ──────────────────────────────────────────────────────────────
PACKAGE=editor

if [ "$#" -gt 0 ]; then
  case "$1" in
    engine|editor)
      PACKAGE=$1
      shift
      ;;
  esac
fi

case "$PACKAGE" in
  engine) PACKAGE_PATH="$ROOT/Engine" ;;
  editor) PACKAGE_PATH="$ROOT/Editor" ;;
esac

export MIMALLOC_DISABLE_REDIRECT=1

if command -v swift-build >/dev/null 2>&1; then
  exec swift-build --package-path "$PACKAGE_PATH" "$@"
fi

exec swift build --package-path "$PACKAGE_PATH" "$@"
