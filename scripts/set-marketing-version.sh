#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/ShellX.xcodeproj/project.pbxproj"
TARGET_NAME="${SHELLX_TARGET:-ShellX}"
VERSION="${1:-}"

usage() {
  cat <<'EOF'
用法：
  ./scripts/set-marketing-version.sh <version>

说明：
  快速更新 ShellX App target 的 MARKETING_VERSION。
  版本号必须使用三段式语义版本，例如 0.2.0。

示例：
  ./scripts/set-marketing-version.sh 0.2.0
EOF
}

if [[ "${VERSION:-}" == "-h" || "${VERSION:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$VERSION" ]]; then
  echo "缺少版本号。" >&2
  usage >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须形如 0.2.0，当前为：$VERSION" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "找不到 Xcode 工程文件：$PROJECT_FILE" >&2
  exit 1
fi

config_ids="$(
  awk -v target="$TARGET_NAME" '
    $0 ~ "/\\* Build configuration list for PBXNativeTarget \"" target "\" \\*/ = \\{" {
      in_target_list = 1
      next
    }
    in_target_list && /buildConfigurations = \(/ {
      in_config_list = 1
      next
    }
    in_target_list && in_config_list && /\);/ {
      exit
    }
    in_target_list && in_config_list {
      token = $1
      if (token ~ /^[A-Fa-f0-9]+$/) {
        print token
      }
    }
  ' "$PROJECT_FILE"
)"

if [[ -z "$config_ids" ]]; then
  echo "无法定位 target '$TARGET_NAME' 的构建配置。" >&2
  exit 1
fi

expected_count="$(printf '%s\n' "$config_ids" | awk 'NF { count++ } END { print count + 0 }')"
tmp_file="$(mktemp "${PROJECT_FILE}.XXXXXX")"

cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

if ! awk -v ids="$config_ids" -v version="$VERSION" -v expected="$expected_count" '
  BEGIN {
    split(ids, id_list, "\n")
    for (idx in id_list) {
      if (id_list[idx] != "") {
        target_config[id_list[idx]] = 1
      }
    }
  }
  $1 in target_config && /\/\* (Debug|Release) \*\/ = \{/ {
    in_target_config = 1
  }
  in_target_config && /MARKETING_VERSION = / {
    sub(/MARKETING_VERSION = [^;]+;/, "MARKETING_VERSION = " version ";")
    updated++
  }
  {
    print
  }
  in_target_config && /^[[:space:]]*};/ {
    in_target_config = 0
  }
  END {
    if (updated != expected) {
      printf "预期更新 %d 处 MARKETING_VERSION，实际更新 %d 处。\n", expected, updated > "/dev/stderr"
      exit 1
    }
  }
' "$PROJECT_FILE" > "$tmp_file"; then
  exit 1
fi

mv "$tmp_file" "$PROJECT_FILE"
trap - EXIT

actual_version="$("$ROOT_DIR/scripts/print-marketing-version.sh")"
if [[ "$actual_version" != "$VERSION" ]]; then
  echo "版本更新后校验失败：期望 $VERSION，实际 $actual_version" >&2
  exit 1
fi

echo "ShellX MARKETING_VERSION 已更新为 $VERSION"
