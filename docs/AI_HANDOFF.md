# AI 交接记录

本文件用于在 Codex、Hermes、Claude Code、Cursor、Windsurf 等编程模型之间传递上下文。每次任务开始前必须读取，每次任务结束前必须更新。

## 项目概览

- 项目：ShellX macOS SSH 会话管理工具。
- 当前形态：Electron/TypeScript 桌面应用。
- 技术栈：Electron、TypeScript、xterm.js、node-pty、Vite。
- 规则入口：`AGENTS.md`、`README.md`、`docs/ui-design-system.md`。
- 旧 Swift/Xcode 工程已从仓库移除，不再新增或维护 Swift、SwiftUI、AppKit、SwiftTerm 代码。

## 启动前检查

- 先读取 `AGENTS.md`、`README.md`、`docs/ui-design-system.md` 和本文件。
- 确认本次改动是否影响终端 PTY、SSH、Keychain、known_hosts、SFTP、lrzsz、自动更新或签名发布。
- 不能完整验证 macOS Electron 打包、签名、DMG、自动更新或真实 SSH 行为时，必须明确说明验证缺口。

## 常用验证命令

```bash
cd electron-shellx
npm run typecheck
npm run build
npm run package:dir

./scripts/build-electron-dmg.sh
```

## 最近交接

- 2026-06-01：用户反馈终端长文本仍像溢出终端或被右侧滚动条区域遮挡。复查 xterm 6 布局后确认上一轮只按 `.xterm-viewport` / 像素安全区估算不够准确：当前实际可见滚动条来自 `.xterm-scrollable-element > .scrollbar.vertical` 自定义滚动条，且 DOM renderer 会给每行设置 `overflow: hidden`，即使右侧有安全区，最后一列字形抗锯齿/overhang 仍可能被 xterm 行自身裁掉。已在 `electron-shellx/src/renderer/main.ts` 改为测量 xterm 自定义滚动条宽度并额外保留文字间距，最小右侧预留提高到 28px，PTY 继续少报 1 列；在 `electron-shellx/src/renderer/styles.css` 隐藏遗留 `.xterm-viewport` 原生滚动条、强制 `.xterm-scrollable-element` 占满终端面板，并允许 `.xterm-rows > div` 的字形边缘溢出到预留安全区。README 已同步说明。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；尚未在 macOS Electron 真机验证 `ps aux`、长 `cat` 输出、滚动条悬停/拖动和不同窗口宽度下的右侧边界。

- 2026-06-01：用户继续反馈终端处理 `lrzsz` 异常，无法上传/下载。复查发现 renderer 用 `\brz\b` 判断上传方向会误把远端 `sz` 的 ZMODEM 自动启动前缀 `rz\r**\x18B00...` 当作远端 `rz` 上传请求，导致本该启动本机 `rz` 下载时错误启动本机 `sz` 上传；旧的上传提示还可能残留在 `recentOutput` 中影响下一次方向判断。已在 `electron-shellx/src/renderer/main.ts` 改为按当前 ZMODEM 触发帧附近内容判断方向：`**\x18B00` / `rz\r**\x18B00` 识别为下载，`**\x18B01` 或 `rz waiting/receive` 识别为上传，并在显示层过滤远端 `sz` 的 `rz\r` 自动启动标记和后续二进制帧，避免终端残留乱码。另在 `electron-shellx/src/main/main.ts` 为 `encoding: null` 的 PTY 输出增加 `StringDecoder`，避免普通 UTF-8 输出跨 chunk 时被 `Buffer.toString("utf8")` 截断成替换字符，同时保持 lrzsz 传输期 raw Buffer 桥接。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；本机通过 node-pty + `/usr/local/bin/rz`/`sz` 做了本地 ZMODEM 上传/下载桥接 smoke test，双向文件均成功。尚未连接真实远端 SSH 执行 `rz` 上传和 `sz 文件` 下载端到端验证。

- 2026-06-01：用户反馈远端执行 `sz mynote.zip` 后只能反复选择目录、无法下载，本地取消后远端命令行残留 ZMODEM 二进制乱码；远端执行 `rz` 选择文件后上传报错。继续分析发现上一轮缓存 ZMODEM 握手时把同一个 PTY chunk 中位于 `**\x18B0` 之前的普通终端文本也一并回放给本机 `rz`/`sz` helper，可能直接污染 ZMODEM 协议；helper 失败后 renderer 又把 `zmodemHandled` 重置为 false，远端 `sz` 重试帧会再次触发目录选择弹窗，形成反复选择。已在 `electron-shellx/src/main/main.ts` 改为只从 `**\x18B0` 起缓存/回放 ZMODEM 数据，并支持起始帧跨 chunk 的短尾扫描；启动 helper 前显式解析本机 `rz`/`sz` 路径，找不到时直接给出“请先安装 lrzsz”并向远端发送取消序列；helper 非零退出或启动失败时会发送 ZMODEM 取消序列并把 stderr 最后一行带入状态消息；传输中普通键盘输入不再写入远端，`Ctrl+C` 会终止本机 helper 并通知远端取消。已在 `electron-shellx/src/renderer/main.ts` 避免启动失败/传输失败后立即重置 `zmodemHandled`，防止同一轮远端重试帧反复弹出文件/目录选择。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；尚未连接真实远端执行 `rz` 上传和 `sz 文件` 下载端到端验证。

- 2026-06-01：用户反馈终端执行 `rz`/`sz` 都有问题，无法上传到远程 SSH 服务器或下载到本地，并补充 `sz` 弹窗像“打开目录”且无法确认传输。分析当前 Electron lrzsz 链路有三个问题：node-pty 默认用 UTF-8 字符串传 PTY 数据，ZMODEM 是二进制协议，非 UTF-8 字节会被破坏；远端 `rz`/`sz` 的 ZMODEM 起始帧会先进入 renderer 触发文件/目录选择，主进程若不缓存这段已到达的握手数据，本地 `sz`/`rz` helper 启动后会错过初始握手；Electron GUI 环境下 `PATH` 可能没有 Homebrew 的 `/opt/homebrew/bin` 或 `/usr/local/bin`，导致本地 `rz`/`sz` 找不到。已在 `electron-shellx/src/main/main.ts` 将 node-pty `encoding` 改为 `null`，传输中以 `Buffer` 原样桥接 PTY 与本地 helper；未启动 transfer 前缓存最多 1 MiB ZMODEM 初始输入，启动本地 helper 后先回放缓存，取消时清空缓存；启动 `/usr/bin/env rz/sz` 时补齐 Homebrew 和系统工具路径。另将目录选择对话框支持 `title`/`buttonLabel`/默认下载目录和 `createDirectory`，renderer 的 `sz` 下载目录选择按钮改为“选择此目录”，避免 macOS 目录选择看起来像“打开目录”。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；尚未连接真实远端执行 `rz` 上传和 `sz 文件` 下载端到端验证。

- 2026-06-01：用户要求清除 GitHub 上的 commit 日志和 Actions 日志。已在保留当前工作树内容的前提下创建新的孤儿 `main` 历史，只保留一个全新根提交并强推到 `origin/main`；`AGENTS.md` 仍保持本地存在且被 `.gitignore` 忽略。Actions workflow runs 删除尝试被 GitHub API 拒绝：当前 GitHub CLI token 返回 `HTTP 403: Resource not accessible by personal access token`，需要换用具备删除 Actions runs 权限的 token 或在 GitHub 网页端清理。注意：GitHub 默认分支历史已被改写为单提交，但旧提交对象可能在 GitHub 后端短期保留，若知道旧 SHA 仍可能暂时打开；此前已清理远端 tags、Release 和非默认分支。

- 2026-06-01：用户要求移除 GitHub 上 `AGENTS.md` 的版本控制、仅本地保留，并清除 GitHub 上 Release/tag/分支数据。已将 `AGENTS.md` 从 Git 索引移除并加入根 `.gitignore`，本地文件仍保留且被忽略；已推送到 `main`。已通过 GitHub CLI/API 删除 GitHub 上 90 个 Release，删除远端和本地 91 个 tag，并删除远端非默认分支 `feature/modernize-ui-design`、`fix/sz-transfer-banner-dismiss`。验证：GitHub Release 数量 0，远端 tag 数量 0，远端分支仅剩 `main`。默认分支 `main` 不能作为普通远端分支直接删除，除非后续删除仓库或先切换默认分支。

- 2026-06-01：用户反馈上轮像素安全区修复后，`ps aux` 等长文本输出的最后一个字符仍有轻微遮挡。进一步判断遮挡不只来自 DOM 右侧滚动条/容器边界，还可能来自 xterm canvas 最后一列自身的字形抗锯齿/字体 overhang 被 canvas 右边界裁切；如果 xterm cols 和 PTY cols 完全一致，长输出仍会落到 xterm 最后一列。已在 `electron-shellx/src/renderer/main.ts` 将右侧像素安全区从 18px 增至 24px，并新增 `terminalPtyRightGuardColumns = 1`：xterm 仍按可视区域 fit，但发给 node-pty 的 cols 比 xterm 可视 cols 少 1，让 `ps aux`、shell/readline 和 TUI 按 PTY 宽度提前 1 列换行，最右侧 xterm 列保留为空白缓冲，避免最后一个字符贴到 canvas 裁切边界。README 已同步说明。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；尚未在 macOS Electron 真机验证 `ps aux` 最后一字符、长命令输入换行和 TUI 宽度。

- 2026-06-01：用户反馈此前 `ps aux` 等长文本输出右侧字符遮挡修复后问题依旧，并要求先彻底分析根因再修复。分析结论：上一轮 `terminalRightGuardColumns = 1` 只在字符列层面少报 1 列，但真实遮挡来自 xterm 视口右侧滚动条/overlay scrollbar、canvas 末列字形抗锯齿外溢和像素取整的像素级占位；字符列和像素遮挡不是同一层，1 列兜底在不同字体、DPR、滚动条策略下不稳定。已在 `electron-shellx/src/renderer/main.ts` 改为读取 xterm 渲染 cell 宽度、viewport 实际 scrollbar 宽度，并按最小 18px 右侧安全区换算实际 cols 后同步给 xterm 和 PTY；同时在 `electron-shellx/src/renderer/styles.css` 为 `.xterm-viewport` 增加 `scrollbar-gutter: stable`，让滚动条占位与列宽计算一致。README 已同步改为像素安全区说明。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；尚未在 macOS Electron 真机验证 `ps aux`、不同窗口宽度、侧栏展开/收起和滚动条显示策略。

- 2026-06-01：用户反馈窗口非最大化时，侧栏折叠后的展开按钮会与 macOS 窗口操作最大化按钮重叠。已在 `electron-shellx/src/renderer/styles.css` 将折叠状态下 `.tabbar`、`.resourcebar` 和 `.detail-page` 的左侧预留从 56/58px 调整为 96px，使 tabbar 内的展开按钮和详情页展开按钮避开 `trafficLightPosition: { x: 16, y: 18 }` 对应的红黄绿窗口按钮区域。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；尚未在 macOS Electron 真机验证非最大化窗口下按钮位置。

- 2026-06-01：用户反馈执行 `ps aux` 等长文本输出命令时，终端右侧部分字符被遮挡。已在 `electron-shellx/src/renderer/main.ts` 将 `terminalRightGuardColumns` 调整为 1，让 xterm fit 后同步给 PTY 的列数比实测可用列数少 1 列，为右侧滚动条和像素取整误差预留空间，避免长行行末压到可视区域边缘。README 已同步说明。验证：`npm run typecheck` 通过，`npm run build` 通过；尚未在 macOS Electron 真机验证 `ps aux` 长行、窗口 resize 后重排和中文 IME 输入。

- 2026-06-01：用户要求优化 UI 样式使其更具现代化科技感，并精简全局设置中“应用更新”的非必要文本。已在 `electron-shellx/src/renderer/styles.css` 调整全局深浅色 token、页面/设置页背景、面板、按钮、侧栏品牌、终端标签、状态栏和详情页视觉层级，增加克制的科技感渐变、描边和聚焦反馈，同时维持 macOS 工具型圆角与密度。已在 `electron-shellx/src/renderer/main.ts` 精简应用更新区域，移除 GitHub Release / SHA256 / 重启安装说明等长说明，只保留自动更新开关、检查更新、重启更新和必要状态文案。验证：`npm run typecheck` 通过，`npm run build` 通过；尚未在 macOS Electron 真机验证设置弹窗、浅色/深色主题和自动更新真实下载/重启安装流程。

- 2026-06-01：用户要求脚本管理的脚本内容提供语法高亮展示。现有渲染层已通过透明 `textarea` 叠加高亮 `pre/code` 实现 Shell/Python 高亮，但全局 `textarea:not(.xterm-helper-textarea)` 表单样式仍会覆盖 `.syntax-input` 的透明文字、背景和尺寸，导致编辑区显示普通文本而非底层高亮。已在 `electron-shellx/src/renderer/styles.css` 将脚本高亮输入框排除出全局 textarea 样式，并为 `.syntax-input` 显式设置 100% 尺寸、透明文字和 WebKit 透明填充，保留光标与底层高亮同步显示。验证：`npm run typecheck` 通过，`npm run build` 通过；尚未在 macOS Electron 真机验证脚本管理窗口中 Shell/Python 高亮、滚动同步和文本选择效果。

- 2026-06-01：用户要求“复制标签”在被复制标签右侧插入，并且新标签名称不要追加“副本”。已在 `electron-shellx/src/renderer/main.ts` 调整 `duplicateTab()`，复制时沿用原标签标题和副标题；`openTerminal()` 新增可选 `insertAfterTabID`，并通过 `insertTab()` 按 Map 顺序把新标签插入源标签后方，其他新建本机终端/连接会话仍默认追加到末尾。验证：`npm run typecheck` 通过，`npm run build` 通过；尚未在 macOS Electron 真机验证标签右键复制后的插入位置和显示名称。

- 2026-06-01：用户反馈 Electron 版偶尔遇到顶部终端标签页无法点击切换，随后补充鼠标移出标签时预览有时没有关闭。分析定位为标签切换只绑定在 `click` 上，而标签按钮同时是 `draggable`，且后台终端输出、连接状态变化、未读状态变化会触发 `renderTabs()` 重建标签 DOM；如果鼠标按下和松开之间发生重绘，原按钮被替换，浏览器不会再触发原 `click`，表现为偶发点击无效。同样，标签 DOM 被重建时原 `mouseleave` 也可能丢失，导致 `.tab-preview` 残留。已在 `electron-shellx/src/renderer/main.ts` 给标签按钮增加左键 `pointerdown` 预激活路径：按下时先切换 `activeTabID`、pane 可见性、状态栏和终端焦点，但不立即重建整个标签栏，只同步当前 DOM 的 `.active` 类；后续正常 `click` 仍会走完整 `activateTab()` 以刷新未读/状态徽标。关闭按钮增加 `pointerdown.stopPropagation()`，避免点关闭时误激活标签。预览处理增加三道兜底：`renderTabs()` 开始先关闭旧预览、窗口 `blur` 关闭预览、全局捕获 `pointermove` 检测指针离开 `.terminal-tab` 后关闭预览。验证：`npm run typecheck` 通过，`npm run build` 通过；尚未在 macOS Electron 真机验证高频输出时连续点击切换、多标签拖拽排序、关闭按钮行为和预览关闭时机。

- 2026-06-01：用户澄清复现是远端终端提示符下输入 `echo ` 后，用中文输入法输入“你好”并回车，结果中文没有进入命令行，而是出现 `.bash_history .bashrc` 这类类似 Tab 补全的输出。继续分析后确认上一轮 Electron SSH locale 修复仍继承了 macOS 图形环境常见的 `LC_CTYPE=UTF-8`，这个值在 Debian/glibc 里不是有效 locale；即使通过 `SetEnv` 发到远端，readline 仍可能回退到 C locale，从而把中文 UTF-8 字节误解释为控制输入/补全行为。已在 `electron-shellx/src/main/main.ts` 改为远端固定使用 Debian 可用性更高的 `C.UTF-8`，`SetEnv` 发送 `LANG=C.UTF-8,LC_CTYPE=C.UTF-8`，并且在 SSH 远端交互 shell 启动前执行 `export LANG=C.UTF-8; export LC_CTYPE=C.UTF-8; exec "${SHELL:-/bin/sh}" -l`，不再依赖服务端是否接受 `AcceptEnv` 才能生效。带启动命令的会话会在启动命令前导出同样 locale。README 已同步说明。验证：`npm run typecheck` 通过，`npm run build` 通过；尚未连接真实 Debian 服务器验证 `locale` 输出和 `echo 你好` 输入回显。

- 2026-06-01：用户反馈 Electron 版左侧折叠按钮 UI 突兀，折叠时与右侧终端重叠，并要求终端渲染实时根据窗口大小动态调整。已在 `electron-shellx/src/renderer/main.ts` / `styles.css` 调整折叠入口：移除覆盖在主工作区左上角的绝对定位 `sidebar-reopen`，折叠后终端工作台把展开按钮作为 tabbar 内的首个 26px 工具按钮，详情页则把展开按钮放在内容流内，避免压住终端标签和内容。终端 resize 方面，将 `ResizeObserver`、`window.resize`、侧栏拖拽和折叠/展开统一调度到 `scheduleActiveTerminalFitAfterLayout()`，使用 requestAnimationFrame 合并并在布局稳定后再次 fit，活动标签会实时 `fit` 并同步 PTY `resize`；标签切换后也走同一调度。延续上一轮修复：表单 CSS 排除 `.xterm-helper-textarea`，PTY 列数与 xterm 实测列数一致，且不再启用 `convertEol`。README 已同步“窗口拖拽缩放实时重新 fit”。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；当前 Linux 环境未执行 `npm run package:dir`，也未在 macOS Electron 真机验证折叠按钮位置、拖拽缩放期间终端实时重排、中文 IME 输入。

- 2026-06-01：用户反馈远端终端中输入 `echo ` 后用中文输入法输入“你好”，结果没有显示中文，却出现类似 `.bash_history .bashrc` 的补全输出。结合现象判断核心不是双击会话问题，而是 xterm 的 IME 输入辅助 textarea 被全局表单样式污染：`electron-shellx/src/renderer/styles.css` 在导入 xterm CSS 后又用全局 `input, textarea, select` / `textarea` / `textarea:focus` 规则设置宽度、边框、背景、padding、min-height、resize 等，覆盖了 `.xterm-helper-textarea` 的隐藏输入和 composition 定位，导致中文组合/提交事件没有稳定进入 xterm/PTY，甚至可能被错误键序列打断。已将表单样式改为排除 `.xterm-helper-textarea`，保留 xterm 自己的 IME textarea 样式；同时延续本轮 readline 修复：`electron-shellx/src/renderer/main.ts` 将 `terminalRightGuardColumns` 改为 0，保证 PTY cols 与 xterm 实测 cols 一致，并移除 `convertEol: true`，让 PTY 原始 CR/LF 控制序列交给 xterm 正常解释。README 已同步移除“右侧保留 1 列安全余量”的说明。验证：`npm run typecheck` 通过，`npm run build` 通过，`git diff --check` 通过；当前 Linux 环境未执行 `npm run package:dir`，也未在 macOS Electron 真机验证中文 IME 输入、bash Tab 补全、长命令换行和窗口 resize 后 readline 重绘。

- 2026-05-31：用户要求移除旧 Swift 代码，全面使用 Electron 代码。已删除 `ShellX/`、`ShellXTests/`、`ShellX.xcodeproj/`、`Config/`、`.build/` 和 Swift/Xcode 专用脚本：`scripts/build-dmg.sh`、`scripts/manual-release-version.sh`、`scripts/print-marketing-version.sh`、`scripts/set-marketing-version.sh`、`scripts/validate-release-tag.sh`。根 README、`AGENTS.md`、`docs/ui-design-system.md`、`electron-shellx/README.md` 和 Electron 发布脚本文案已改为 Electron-only；`electron-shellx/.gitignore` 也补充忽略生成的 `build/` 图标目录。仍保留 Electron 主进程中的旧数据迁移逻辑，用于从用户机器的历史 ShellX 应用支持目录导入会话、脚本和 known_hosts；这不是旧 Swift 应用代码。验证：`npm run typecheck` 通过，`npm run build` 通过，`bash -n` 检查根目录 Electron 脚本通过，`git diff --check` 通过。未执行 `npm run package:dir` / DMG 构建和 macOS 真机回归。

- 2026-05-31：用户反馈 Electron 版连接 Debian 后，在 `echo "` 后输入中文并回车，中文没有输出且表现得像触发 Tab 补全。已定位 Electron 链路：xterm `terminal.onData()` 直接把输入写给主进程 PTY，主进程 `terminal:write` 也直接 `ptyProcess.write()`，没有自定义中文输入转换；本地 PTY 复现实验证明 bash/readline 在 `LANG=C LC_CTYPE=C` 下接收中文 UTF-8 字节会出现响铃、擦除和类似补全的行为，而 UTF-8 locale 下正常。因此问题是 Electron 版 `sshArgs()` 只设置本机 ssh 进程环境，未通过 OpenSSH `SendEnv` / `SetEnv` 给远端会话发送 `LANG` / `LC_CTYPE`。已在 `electron-shellx/src/main/main.ts` 新增 SSH 环境参数，发送 `LANG`、`LC_CTYPE`、`BUILDKIT_PROGRESS=plain` 和 `COMPOSE_PROGRESS=plain`，并同步 README。验证：`npm run typecheck` 通过，`npm run build` 通过。未连接真实 Debian 服务器验证远端 `locale` 与中文输入回显。

## 待办与风险

- 需要在 macOS 真机验证 Electron App：终端中文输入、SSH locale、标签切换、lrzsz/SFTP、Keychain 自动回填、自动更新下载和重启安装。
- `scripts/build-electron-dmg.sh` 当前默认使用 `electron-builder --mac dir` 产物路径 `release/mac-arm64/ShellX.app`，跨架构/通用架构发布策略仍需补强。
- Electron 主进程保留从旧 ShellX 数据目录迁移用户数据的逻辑；删除或修改前要确认不会造成用户会话、脚本、known_hosts 丢失。
