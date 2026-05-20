#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export MIMALLOC_DISABLE_REDIRECT=1

_run_bootstrap() {
    swift package --package-path "$ROOT/Engine" \
        --allow-writing-to-package-directory build-native-deps "$@"
    swift package --package-path "$ROOT/GuavaUI" \
        --allow-writing-to-package-directory build-native-deps "$@"
}

_needs_bootstrap() {
    [ ! -d "$ROOT/Engine/vendor/SDL3.artifactbundle" ] || \
    [ ! -d "$ROOT/GuavaUI/vendor/yoga.artifactbundle" ]
}

# ── explicit bootstrap (supports --force) ────────────────────────────────────
if [ "$#" -gt 0 ] && [ "$1" = "bootstrap" ]; then
    shift
    _run_bootstrap "$@"
    exit 0
fi

# ── swift build (auto-bootstrap if vendor is missing) ────────────────────────
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

if _needs_bootstrap; then
    echo "vendor/ missing — running bootstrap first..."
    _run_bootstrap
fi

if command -v swift-build >/dev/null 2>&1; then
  exec swift-build --package-path "$PACKAGE_PATH" "$@"
fi

exec swift build --package-path "$PACKAGE_PATH" "$@"
