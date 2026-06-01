#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELECTRON_DIR="$ROOT_DIR/electron-shellx"
APP_NAME="ShellX.app"
BUILT_APP="$ELECTRON_DIR/release/mac-arm64/$APP_NAME"
INSTALL_APP="/Applications/$APP_NAME"

log() {
  printf '[ShellX install] %s\n' "$*"
}

fail() {
  printf '[ShellX install] ERROR: %s\n' "$*" >&2
  exit 1
}

command -v npm >/dev/null 2>&1 || fail "未找到 npm，请先安装 Node.js。"
command -v codesign >/dev/null 2>&1 || fail "未找到 codesign，请确认正在 macOS 上执行。"
command -v xattr >/dev/null 2>&1 || fail "未找到 xattr，请确认正在 macOS 上执行。"

[[ -d "$ELECTRON_DIR" ]] || fail "未找到 Electron 工程目录：$ELECTRON_DIR"

log "构建并打包 Electron 版 ShellX"
(
  cd "$ELECTRON_DIR"
  if [[ ! -d node_modules ]]; then
    log "安装 npm 依赖"
    npm install
  fi
  npm run package:dir
)

[[ -d "$BUILT_APP" ]] || fail "打包产物不存在：$BUILT_APP"

log "退出正在运行的 ShellX"
osascript -e 'tell application "ShellX" to quit' >/dev/null 2>&1 || true
sleep 1

if [[ -e "$INSTALL_APP" ]]; then
  BACKUP_APP="/Applications/ShellX.app.backup.$(date +%Y%m%d-%H%M%S)"
  log "备份现有应用到 $BACKUP_APP"
  mv "$INSTALL_APP" "$BACKUP_APP"
fi

log "安装到 $INSTALL_APP"
cp -R "$BUILT_APP" "$INSTALL_APP"

log "清理隔离属性并执行 ad-hoc 签名"
xattr -cr "$INSTALL_APP"
codesign --force --deep --sign - "$INSTALL_APP"
xattr -cr "$INSTALL_APP"
touch "$INSTALL_APP"

if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
  log "刷新 LaunchServices 图标缓存"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP" >/dev/null 2>&1 || true
fi

log "重启 Dock 以刷新程序坞图标"
killall Dock >/dev/null 2>&1 || true

log "校验签名"
codesign --verify --deep --strict --verbose=2 "$INSTALL_APP"

log "打开 ShellX"
open "$INSTALL_APP"

log "完成。数据目录：$HOME/Library/Application Support/shellx-electron/workspace"
