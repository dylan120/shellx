#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELECTRON_DIR="$ROOT_DIR/electron-shellx"
OUTPUT_DIR="$ROOT_DIR/dist"
VOLUME_NAME="ShellX"
APP_NAME="ShellX"
EXPECTED_BUNDLE_ID="com.example.ShellX"

usage() {
  cat <<'EOF'
用法：
  ./scripts/build-electron-dmg.sh [选项]

说明：
  构建 Electron/TypeScript 版 ShellX.app，并封装为 ShellX 自动更新器可识别的 DMG。
  产物默认输出为 ./dist/ShellX-Release.dmg 和 ./dist/ShellX-Release.dmg.sha256。

选项：
  --output-dir <path>    指定输出目录，默认 ./dist
  --volume-name <name>   指定 DMG 卷名，默认 ShellX
  -h, --help             显示帮助
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

run() {
  echo "+ $*"
  "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
done

require_command npm
require_command hdiutil
require_command shasum
require_command codesign
require_command xattr
require_command /usr/libexec/PlistBuddy

[[ -d "$ELECTRON_DIR" ]] || die "未找到 Electron 工程目录：$ELECTRON_DIR"

run mkdir -p "$OUTPUT_DIR"

(
  cd "$ELECTRON_DIR"
  if [[ ! -d node_modules ]]; then
    run npm install
  fi
  run npm run package:dir
)

BUILT_APP="$ELECTRON_DIR/release/mac-arm64/$APP_NAME.app"
[[ -d "$BUILT_APP" ]] || die "未找到打包产物：$BUILT_APP"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || die "Bundle ID 必须保持 ShellX 更新兼容：期望 $EXPECTED_BUNDLE_ID，实际 $BUNDLE_ID"

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$BUILT_APP/Contents/Info.plist")"
[[ -x "$BUILT_APP/Contents/MacOS/$EXECUTABLE_NAME" ]] || die "未找到可执行文件：$BUILT_APP/Contents/MacOS/$EXECUTABLE_NAME"

run xattr -cr "$BUILT_APP"
run codesign --force --deep --sign - "$BUILT_APP"
run codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

DMG_PATH="$OUTPUT_DIR/ShellX-Release.dmg"
SHA_PATH="$DMG_PATH.sha256"
STAGING_DIR="$OUTPUT_DIR/.electron-dmg-staging"

run rm -rf "$STAGING_DIR"
run mkdir -p "$STAGING_DIR"
run cp -R "$BUILT_APP" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

run rm -f "$DMG_PATH" "$SHA_PATH"
run hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
run shasum -a 256 "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$SHA_PATH"
run rm -rf "$STAGING_DIR"

echo "Electron DMG 构建完成："
echo "  APP: $BUILT_APP"
echo "  Bundle ID: $BUNDLE_ID"
echo "  DMG: $DMG_PATH"
echo "  SHA256: $SHA_PATH"
