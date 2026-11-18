#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"

mkdir -p "$PROJECT_DIR/.build/clang-module-cache" "$PROJECT_DIR/.build/swiftpm-module-cache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swiftpm-module-cache"

echo "==> Running GmailPushBridge unit tests…"
swift test --disable-sandbox "$@"

echo "==> Verifying release build…"
swift build -c release --disable-sandbox

echo "==> All checks passed!"
