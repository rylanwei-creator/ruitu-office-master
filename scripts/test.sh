#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${RUITU_BUILD_ROOT:-$PROJECT_ROOT/.build}"
mkdir -p "$BUILD_ROOT/test-data"
FLAGS=(--package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/spm-cache" --config-path "$BUILD_ROOT/spm-config" --security-path "$BUILD_ROOT/spm-security" -Xswiftc -module-cache-path -Xswiftc "$BUILD_ROOT/modules")
if [[ "${RUITU_DISABLE_SWIFTPM_SANDBOX:-0}" == 1 ]]; then FLAGS+=(--disable-sandbox); fi
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang"
export RUITU_TEST_MODE=1
export RUITU_WORK_DIRECTORY="$BUILD_ROOT/test-data"
swift test "${FLAGS[@]}"
