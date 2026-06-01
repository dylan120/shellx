#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELECTRON_DIR="$ROOT_DIR/electron-shellx"
REMOTE_NAME="${SHELLX_REMOTE:-origin}"
MAIN_BRANCH="${SHELLX_MAIN_BRANCH:-main}"
VERSION=""
ASSUME_YES=0
SKIP_TESTS=0
OUTPUT_DIR="$ROOT_DIR/dist"
RELEASE_NOTES=""

usage() {
  cat <<'EOF'
用法：
  ./scripts/manual-release-electron-version.sh <version> [选项]

说明：
  发布 Electron/TypeScript 版 ShellX，生成 ShellX 自动更新器可安装的 ShellX-Release.dmg。
  Release tag 使用 v<version>，应用会通过 GitHub latest Release 检查并自动更新到新版 Electron App。

选项：
  --yes, -y              跳过最终确认
  --skip-tests           跳过 npm typecheck/build 预检
  --output-dir <path>    指定 DMG 输出目录，默认 ./dist
  --notes <text>         指定 Release 说明；默认自动生成提交清单
  -h, --help             显示帮助

示例：
  ./scripts/manual-release-electron-version.sh 0.9.0
  ./scripts/manual-release-electron-version.sh 0.9.0 --yes
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --yes|-y)
        ASSUME_YES=1
        shift
        ;;
      --skip-tests)
        SKIP_TESTS=1
        shift
        ;;
      --output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --notes)
        RELEASE_NOTES="$2"
        shift 2
        ;;
      -* )
        die "未知参数：$1"
        ;;
      *)
        if [[ -n "$VERSION" ]]; then
          die "只能传入一个版本号，已收到：$VERSION 和 $1"
        fi
        VERSION="$1"
        shift
        ;;
    esac
  done
}

ensure_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
    die "工作区不干净。请先提交或暂存无关修改后再发布。"
  fi
}

confirm_release() {
  local tag_name="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return
  fi

  cat <<EOF
即将发布 Electron/TypeScript 版 ShellX：
  当前分支：$(git branch --show-current)
  目标主分支：${REMOTE_NAME}/${MAIN_BRANCH}
  版本号：${VERSION}
  Tag：${tag_name}
  输出目录：${OUTPUT_DIR}
  Release 资产：ShellX-Release.dmg + ShellX-Release.dmg.sha256

注意：这会创建 Git tag 和 GitHub Release。ShellX 自动更新器会把该 Release 当成最新版本，并安装 DMG 内的 Electron ShellX.app。
EOF

  read -r -p "确认继续？输入 yes 继续：" answer
  if [[ "$answer" != "yes" ]]; then
    die "已取消发布。"
  fi
}

create_release_notes() {
  local tag_name="$1"
  local notes_file="$2"

  if [[ -n "$RELEASE_NOTES" ]]; then
    printf '%s\n' "$RELEASE_NOTES" > "$notes_file"
    return
  fi

  local previous_tag=""
  previous_tag="$(git tag --sort=-v:refname | awk -v current="$tag_name" '$0 != current { print; exit }')"
  {
    echo "## 本次更新清单"
    echo
    echo "发布形态：Electron/TypeScript 版 ShellX"
    echo
    if [[ -n "$previous_tag" ]]; then
      echo "范围：${previous_tag} -> ${tag_name}"
      echo
      git log --no-merges --reverse --pretty=format:'- %s (`%h`)' "${previous_tag}..HEAD" | sed 's/``` //g'
    else
      echo "范围：${tag_name}"
      echo
      git log --no-merges --reverse --pretty=format:'- %s (`%h`)' HEAD | sed 's/``` //g'
    fi
    echo
  } > "$notes_file"
}

run_tests_if_needed() {
  if [[ "$SKIP_TESTS" -eq 1 ]]; then
    echo "已按参数跳过 npm 预检。"
    return
  fi
  (
    cd "$ELECTRON_DIR"
    run npm run typecheck
    run npm run build
  )
}

parse_args "$@"

if [[ -z "$VERSION" ]]; then
  read -r -p "请输入发布版本号（例如 0.9.0）：" VERSION
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号必须形如 0.9.0，当前为：$VERSION"

cd "$ROOT_DIR"
require_command git
require_command gh
require_command npm
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "当前目录不是 Git 仓库。"
[[ -d "$ELECTRON_DIR" ]] || die "未找到 Electron 工程目录：$ELECTRON_DIR"

current_branch="$(git branch --show-current)"
[[ "$current_branch" == "$MAIN_BRANCH" ]] || die "请先切换到 ${MAIN_BRANCH} 再发布，当前分支：${current_branch}"

tag_name="v${VERSION}"

ensure_clean_worktree

run git fetch "$REMOTE_NAME" --prune --tags

if git rev-parse "$tag_name" >/dev/null 2>&1; then
  die "本地 tag 已存在：$tag_name"
fi
if git ls-remote --exit-code --tags "$REMOTE_NAME" "refs/tags/${tag_name}" >/dev/null 2>&1; then
  die "远端 tag 已存在：$tag_name"
fi
if ! git merge-base --is-ancestor "${REMOTE_NAME}/${MAIN_BRANCH}" "$MAIN_BRANCH"; then
  die "当前 ${MAIN_BRANCH} 未包含最新 ${REMOTE_NAME}/${MAIN_BRANCH}，请先 git pull --ff-only。"
fi

confirm_release "$tag_name"

(
  cd "$ELECTRON_DIR"
  run npm version "$VERSION" --no-git-tag-version --allow-same-version
)

if [[ -n "$(git status --porcelain -- electron-shellx/package.json electron-shellx/package-lock.json)" ]]; then
  run git add "$ELECTRON_DIR/package.json" "$ELECTRON_DIR/package-lock.json"
  run git commit -m "chore: release ${tag_name} electron"
else
  echo "Electron package 版本已经是 ${VERSION}，不需要创建版本提交。"
fi

run_tests_if_needed

run "$ROOT_DIR/scripts/build-electron-dmg.sh" --output-dir "$OUTPUT_DIR" --volume-name "ShellX ${tag_name}"

dmg_path="$OUTPUT_DIR/ShellX-Release.dmg"
sha_path="$OUTPUT_DIR/ShellX-Release.dmg.sha256"
[[ -f "$dmg_path" ]] || die "未找到 DMG：$dmg_path"
[[ -f "$sha_path" ]] || die "未找到 SHA256：$sha_path"

run git tag -a "$tag_name" -m "ShellX ${tag_name}"
notes_file="$(mktemp "$ROOT_DIR/.release-notes.XXXXXX")"
trap 'rm -f "$notes_file"' EXIT
create_release_notes "$tag_name" "$notes_file"

run git push "$REMOTE_NAME" "$MAIN_BRANCH"
run git push "$REMOTE_NAME" "$tag_name"

run gh release create "$tag_name" \
  "${dmg_path}#ShellX-Release.dmg" \
  "${sha_path}#ShellX-Release.dmg.sha256" \
  --title "ShellX ${tag_name}" \
  --notes-file "$notes_file" \
  --verify-tag

echo "Electron 手动发布完成：${tag_name}"
