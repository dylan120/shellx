#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ShellX.xcodeproj"
SCHEME="ShellX"
CONFIGURATION="Release"
APP_NAME="ShellX"
OUTPUT_DIR="$ROOT_DIR/dist"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
VOLUME_NAME="ShellX"

usage() {
  cat <<'EOF'
用法：
  ./scripts/build-dmg.sh [选项]

说明：
  构建未签名的 ShellX.app，并封装成一个可分发的 dmg 安装包。

选项：
  --scheme <name>           指定 Xcode Scheme，默认 ShellX
  --configuration <name>    指定构建配置，默认 Release
  --app-name <name>         指定 .app 名称，默认 ShellX
  --output-dir <path>       指定输出目录，默认 ./dist
  --volume-name <name>      指定 dmg 挂载卷名，默认 ShellX
  --derived-data <path>     指定 DerivedData 目录，默认 ./.build/DerivedData
  -h, --help                显示帮助

示例：
  ./scripts/build-dmg.sh
  ./scripts/build-dmg.sh --configuration Debug --output-dir ./artifacts
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheme)
      SCHEME="$2"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="$2"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令：$1" >&2
    exit 1
  fi
}

require_command xcodebuild
require_command hdiutil

mkdir -p "$OUTPUT_DIR"
mkdir -p "$DERIVED_DATA_DIR"

BUILD_PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION"
APP_PATH="$BUILD_PRODUCTS_DIR/$APP_NAME.app"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-${CONFIGURATION}.dmg"
STAGING_DIR="$OUTPUT_DIR/.dmg-staging"

echo "开始构建 $APP_NAME.app ..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "未找到构建产物：$APP_PATH" >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
echo "开始封装 dmg：$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "构建完成："
echo "  APP: $APP_PATH"
echo "  DMG: $DMG_PATH"
