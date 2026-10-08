#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${RUITU_BUILD_ROOT:-$PROJECT_ROOT/.build}"
RESOURCES="$PROJECT_ROOT/Sources/RuiTuOfficeMaster/macOS/Resources"
mkdir -p "$BUILD_ROOT"
ICON_WORK_DIRECTORY="$(mktemp -d "$BUILD_ROOT/icon-build.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIRECTORY"' EXIT
ICONSET="$ICON_WORK_DIRECTORY/AppIcon.iconset"
mkdir -p "$ICONSET"
# 由独立的圆角 AppIcon.png 生成标准尺寸；软件内透明 Logo.png 独立使用。
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$RESOURCES/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE_SIZE="$((SIZE * 2))"
    sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$RESOURCES/AppIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
# 小尺寸使用预乘 ARGB，避免 PNG 图块被系统按旧格式误解码。
swift -module-cache-path "$BUILD_ROOT/icon-modules" "$PROJECT_ROOT/scripts/pack-icon.swift" "$ICONSET" "$ICON_WORK_DIRECTORY/AppIcon.icns"
# 使用系统解码器确认 ICNS 可以读取，再发布到项目资源。
iconutil --convert iconset --output "$ICON_WORK_DIRECTORY/Verified.iconset" "$ICON_WORK_DIRECTORY/AppIcon.icns"
mv "$ICON_WORK_DIRECTORY/AppIcon.icns" "$RESOURCES/AppIcon.icns"
