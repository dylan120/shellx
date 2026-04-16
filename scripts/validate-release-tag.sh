#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_NAME="${1:-}"

if [[ -z "$TAG_NAME" ]]; then
  echo "用法：$0 <tag-name>" >&2
  exit 1
fi

if [[ ! "$TAG_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Release tag 必须形如 v0.2.0，当前为：$TAG_NAME" >&2
  exit 1
fi

tag_version="${TAG_NAME#v}"
marketing_version="$("$ROOT_DIR/scripts/print-marketing-version.sh")"

if [[ "$tag_version" != "$marketing_version" ]]; then
  echo "Release tag 与 MARKETING_VERSION 不一致：tag=$tag_version, MARKETING_VERSION=$marketing_version" >&2
  exit 1
fi

echo "Release tag 与 MARKETING_VERSION 一致：$TAG_NAME"
