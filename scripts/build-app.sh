#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${RUITU_BUILD_ROOT:-$PROJECT_ROOT/.build}"
RELEASE_DIR="$PROJECT_ROOT/release"
mkdir -p "$BUILD_ROOT" "$RELEASE_DIR"
RUITU_BUILD_ROOT="$BUILD_ROOT" "$PROJECT_ROOT/scripts/build-icon.sh"
FLAGS=(--package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/spm-cache" --config-path "$BUILD_ROOT/spm-config" --security-path "$BUILD_ROOT/spm-security" -Xswiftc -module-cache-path -Xswiftc "$BUILD_ROOT/modules")
if [[ "${RUITU_DISABLE_SWIFTPM_SANDBOX:-0}" == 1 ]]; then FLAGS+=(--disable-sandbox); fi
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang"
# MLX release is Apple Silicon-only. The source still targets macOS 14.
swift build -c release --jobs 2 --product RuiTuOfficeMaster "${FLAGS[@]}" --arch arm64
BIN_DIR="$(swift build -c release "${FLAGS[@]}" --arch arm64 --show-bin-path)"
APP_BINARY="$BIN_DIR/RuiTuOfficeMaster"
RUITU_BUILD_ROOT="$BUILD_ROOT" python3 "$PROJECT_ROOT/scripts/build-metal.py"
APP="$RELEASE_DIR/锐途办公大师.app"
STAGE="$RELEASE_DIR/.app-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$APP_BINARY" "$STAGE/Contents/MacOS/RuiTuOfficeMaster"
cp "$BUILD_ROOT/metal/mlx.metallib" "$STAGE/Contents/MacOS/mlx.metallib"
for BUNDLE in "$BIN_DIR"/*.bundle; do
    if [[ -d "$BUNDLE" ]]; then cp -R "$BUNDLE" "$STAGE/Contents/Resources/"; fi
done
cp "$PROJECT_ROOT/Sources/RuiTuOfficeMaster/macOS/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
python3 -c 'from pathlib import Path
import plistlib, sys
app = Path(sys.argv[1])
info = {
    "CFBundleName": "RuiTuOfficeMaster", "CFBundleDisplayName": "锐途办公大师",
    "CFBundleIdentifier": "com.ruitu.officemaster", "CFBundleExecutable": "RuiTuOfficeMaster",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.9.0", "CFBundleVersion": "47",
    "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "NSSpeechRecognitionUsageDescription": "使用系统本地语音识别，将你选择的音视频文件转成文字。"
}
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))' "$STAGE"
cp -R "$PROJECT_ROOT/THIRD_PARTY_NOTICES" "$STAGE/Contents/Resources/"
codesign --force --deep --sign - --options runtime "$STAGE"
codesign --verify --deep --strict "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
ZIP="$RELEASE_DIR/RuituOfficeMaster_1.9.0_AppleSilicon.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
file "$APP/Contents/MacOS/RuiTuOfficeMaster"
printf '成品：%s\n' "$APP" "$ZIP"
