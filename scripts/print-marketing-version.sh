#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ShellX.xcodeproj"
SCHEME="${SHELLX_SCHEME:-ShellX}"
CONFIGURATION="${SHELLX_CONFIGURATION:-Release}"

if command -v xcodebuild >/dev/null 2>&1; then
  version="$(
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      CODE_SIGNING_ALLOWED=NO \
      -showBuildSettings 2>/dev/null \
      | awk -F= '/MARKETING_VERSION/ {
          value = $2
          gsub(/^[ \t]+|[ \t]+$/, "", value)
          print value
          exit
        }'
  )"
else
  # CI 上优先使用 xcodebuild；这个兜底让无 Xcode 环境也能做基础脚本检查。
  version="$(
    awk '
      /\/\* Release \*\// { in_release = 1 }
      in_release && /MARKETING_VERSION = / {
        value = $3
        gsub(/;/, "", value)
        print value
        exit
      }
    ' "$PROJECT_PATH/project.pbxproj"
  )"
fi

if [[ -z "${version:-}" ]]; then
  echo "无法读取 MARKETING_VERSION。" >&2
  exit 1
fi

echo "$version"
