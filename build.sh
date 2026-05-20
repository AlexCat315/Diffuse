#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
  engine|editor)
    ;;
  *)
    PACKAGE=editor
    ;;
esac

case "$PACKAGE" in
  engine) PACKAGE_PATH="$ROOT/Engine" ;;
  editor) PACKAGE_PATH="$ROOT/Editor" ;;
esac

export MIMALLOC_DISABLE_REDIRECT=1

if command -v swift-build >/dev/null 2>&1; then
  exec swift-build --package-path "$PACKAGE_PATH" "$@"
fi

exec swift build --package-path "$PACKAGE_PATH" "$@"
