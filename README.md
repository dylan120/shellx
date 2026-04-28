# ShellX

ShellX 是一个面向 macOS 的原生 SSH 会话管理工具，重点解决以下问题：

- 通过文件夹树组织和管理 SSH 会话
- 在主窗口中完成新增、编辑、搜索、复制和删除
- 在主窗口详情区内以标签页形式打开多个 SSH 控制台

## 当前实现范围

本仓库当前提供一版可直接在 Xcode 中打开的 MVP 工程，包含：

- 原生 `SwiftUI` macOS App 工程骨架
- 默认以前台 macOS 应用方式运行，会在程序坞和应用切换器中显示图标
- 工程内置最小 AppIcon 资源，默认在程序坞中显示 ShellX 图标
- 应用启动后默认打开一个本机终端标签，优先使用 `/bin/zsh` 作为本地 shell
- 应用菜单“文件”下提供“全局配置”入口，可统一管理界面主题、窗口行为、鼠标 / 触控板行为和终端历史行数上限
- 顶部菜单栏提供“脚本”入口，可管理常用脚本并批量选择会话执行
- 全局配置支持检查 GitHub Release 更新，可开启启动时自动后台更新，也可手动检查并显示下载进度
- 本地 JSON 持久化的文件夹树和 SSH 会话配置
- 会话管理窗口：左侧文件夹/会话树、详情面板、搜索、编辑
- 会话管理、终端工作台、脚本管理和全局配置已统一为原生 macOS 工具型视觉风格，包含更清晰的分组面板、状态胶囊、标签样式和主次操作层级
- 基于 `SwiftTerm` + 自管 PTY + 系统 `/usr/bin/ssh` 的内嵌终端标签页，可运行交互式 SSH 会话和常见 TUI 程序
- 终端支持增强版 `lrzsz`：远端 `rz` 时可多选本地文件上传，远端 `sz` 时可选本地目录接收，并在终端底部栏持续展示进度与速率
- 当前活跃 SSH 会话支持通过系统 `/usr/bin/sftp` 发起文件和文件夹上传/下载
- 连接前支持 ShellX 自己的 `known_hosts` 首次确认，私钥模式支持复用 macOS/OpenSSH `UseKeychain`
- 支持账号密码认证；当远端真正提示密码时，ShellX 会优先从系统 Keychain 读取并自动回填，未命中时再提示输入一次
- 支持本地脚本库，脚本保存在应用支持目录并可通过全部会话树选择目标会话批量执行

## 关键假设

- 当前版本是本地单用户桌面应用，不涉及云同步或多人协作
- 当前版本优先支持 `SSH Agent`、私钥和账号密码认证
- 当前终端窗口基于 `SwiftTerm`，优先提供接近原生终端的交互体验

## 功能说明

### 会话管理

- 支持新建顶级文件夹和子文件夹
- 支持在左侧“全部会话”右键菜单中新建根层级会话或文件夹
- 支持在左侧文件夹菜单中直接在当前文件夹下新建会话
- 支持在左侧文件夹树中直接展开查看会话，并按文件夹树筛选会话
- 支持在左侧“全部会话”树中拖动会话或文件夹到其他文件夹；拖到“全部会话”可移回根层级
- 支持新建、编辑、复制、删除 SSH 会话
- 支持按会话名称、主机、用户名搜索

### SSH 连接

- 支持配置主机、端口、用户名、私钥文件、启动后预执行命令
- 支持为会话配置多个标签，用于环境、角色和用途标记
- 私钥认证模式下，会话编辑页通过本机文件选择窗口选取私钥文件，不需要手动填写路径
- 账号密码认证模式下，可在会话编辑页重新设置登录密码；保存时会立即新建或刷新系统 Keychain 条目，留空保存则保持现有已保存密码不变
- 连接时调用系统 `ssh` 命令，参数由会话配置拼装；首次连接和已信任主机都会以前置 `ssh-keyscan` 对比当前可用 host key 集合，发现服务器新增算法时会提示确认更新，再交给 OpenSSH 使用本地记录严格校验
- SSH 会话启动时会为本地 `ssh` 客户端补齐 UTF-8 locale，并显式发送 `LANG` / `LC_CTYPE` 到远端，尽量避免图形环境缺少 locale 时出现中文输入回显乱码、列宽计算异常或表格错位
- 终端标签页支持键盘输入、ANSI/TUI 渲染、断开连接、重连
- 终端输入会将增强键盘协议下的可打印字符和 Ctrl 组合键归一化为普通 UTF-8 或传统控制字节，避免断开重连后远端 shell 将 `CSI u` 序列回显到提示符
- lrzsz 与 SFTP 上传下载进行中按 `Ctrl+C` 会取消当前传输，并清理本地 helper / sftp 子进程
- 默认会先打开一个“本机终端”标签；你仍可继续从左侧会话树打开 SSH 标签，并在顶部标签栏间切换
- 默认打开的“本机终端”会以非 login shell 方式启动；复制出来的新本机终端标签同样使用非 login shell，避免重复加载 login 初始化逻辑
- 本机终端启动时会同步更新子进程的 `SHELL` 环境变量，使其与实际启动的 shell 一致，避免 `echo $SHELL` 与真实进程不一致
- 本机终端启动时会优先继承宿主进程已有的 `LANG` / `LC_ALL` / `LC_CTYPE`；若图形环境未提供 locale，则兜底为 UTF-8，避免 `ls` 等命令显示中文目录名乱码
- 终端子进程启动时会使用当前视图的实际列数和行数创建 PTY；拖动调整窗口大小后，也会把最新尺寸同步给 PTY，让 shell、长行输出和常见 TUI 程序按新窗口宽高重排
- 同一个 SSH 会话支持同时打开多个独立标签；每个标签都会维护自己独立的终端实例和连接状态
- 后台终端标签会保持连接并持续维护各自的终端屏幕状态；切换标签时只允许当前活动标签接收键盘输入，避免输入串到其他标签
- 顶部标签支持拖动自由排序
- 终端标签操作位于顶部栏，通过右击标签菜单执行切换、复制到新标签、重连、断开、复制调试、清空调试、关闭右侧标签页、关闭其他标签页、关闭所有标签页和关闭；复制出的新标签会插入到源标签右侧
- 所有关闭终端标签的操作都会先弹出确认窗口，用户确认后才会断开连接并关闭标签页
- 终端内容区支持右击菜单，可执行复制当前选中文本、粘贴系统剪贴板内容和关闭当前标签页
- 终端内容区左侧保留少量输出留白，避免靠左拖拽复制文本时误触发侧栏宽度调整
- 终端内容区在鼠标拖拽选区到可视区域上下边缘时，会自动滚动并继续扩展选区，便于跨屏选取长文本
- 终端内容区优先保留原生文本选择能力，历史输出和持续输出中的已显示文本都可直接拖拽选中；因此不会把鼠标拖拽上报给启用鼠标协议的终端程序
- 终端内容区在用户滚动到历史输出后继续输入命令时，会自动回到最新输出位置，避免命令结果已写入底部但当前视口仍停留在历史区造成误判
- “复制调试”会同时带出密码存储访问日志和 SSH 密码自动填充事件，可用于判断远端密码提示后是否真的读取了 Keychain、以及密码是否实际写入了 SSH PTY
- 当前会话状态、主机地址与工作目录展示位于终端底部栏，减少顶部操作干扰
- 当前会话状态、主机地址、工作目录与会话标签展示位于终端底部栏，便于快速识别当前环境
- 终端底部栏的主机地址旁提供复制按钮，可一键复制当前连接地址到系统剪贴板
- 终端底部栏中的会话标签会根据浅色 / 深色主题自动调整前景、底色和描边对比度，避免标签在不同主题下发灰或难以辨认
- 全局配置中的“界面主题”支持跟随系统、浅色和深色三种模式，切换后会立即作用于当前应用窗口
- 全局配置中的“重新打开上次标签页”可控制关闭主窗口后再次打开时是否恢复关闭前仍在顶部标签栏中的终端标签；恢复多个标签时只会自动连接当前活动标签，其他标签会在切换到前台后再连接，避免重启后同时发起多条 SSH 连接被远端提前断开；关闭该选项后，关闭主窗口会同时结束当前终端连接，下次打开回到默认状态
- 全局配置中的“选中文本复制”可控制终端选区变化后是否自动复制到系统剪贴板；说明通过问号图标悬停提示展示
- 全局配置中的“终端历史行数上限”会立即作用于已打开标签，用于限制 scrollback 历史，降低长时间刷屏时的内存增长
- 全局配置中的“应用更新”会读取 `https://api.github.com/repos/dylan120/shellx/releases/latest`，将 Release `tag_name`（例如 `v0.2.0`）与当前应用版本比较；Release 需要附带 `.dmg` 或 `.zip` 安装资产以及同名 `.sha256` 校验文件，手动更新时会显示下载进度
- 开启“自动更新”后，ShellX 启动时会后台检查 GitHub Release；发现新版本后会自动下载，下载完成后在应用更新区域提示“立即重启”，由用户决定何时安装并重启生效
- 终端底部的普通状态提示会自动消失；只有连接失败等真实错误才会继续保留为错误信息，并提供“复制错误”
- 支持 `lrzsz` 双向文件传输触发、多文件上传，以及在终端底部栏持续展示进度与速率
- lrzsz helper 会显式开启 verbose 输出，以便持续解析文件名、字节数、速率和 ETA
- 当前已连接标签支持通过右击标签菜单发起 `SFTP 上传文件/文件夹`、`SFTP 下载文件` 和 `SFTP 下载文件夹`
- SFTP 传输进行中会在终端底部栏展示当前文件、百分比、已传输大小、速率和剩余时间（以远端 `sftp` 进度输出为准）
- 首次连接未知主机、主机指纹变更或服务器新增 host key 算法时都会展示指纹确认；私钥模式可启用 Keychain 集成；账号密码模式下会在远端真正提示密码时再尝试读取 Keychain 并自动回填
- 顶部菜单“脚本”提供“脚本管理”和“批量执行脚本”两个入口；脚本管理支持新增、编辑、删除脚本，并可在 Shell / Python 语法之间切换高亮
- 脚本管理的脚本内容区域支持打开大窗口查看和编辑，适合检查较长脚本；大窗口复用同一份草稿内容和语法高亮配置
- 批量执行脚本窗口复用全部会话树选择目标会话，支持为本次执行手动输入参数和超时时间，并在同一窗口展示每个会话的执行中、成功或失败状态；点击具体会话可查看该会话输出，也可终止选中主机或一键终止全部运行中的主机
- 批量脚本通过系统 `/usr/bin/ssh` 非交互执行到远端 `sh -s -- ...`，手动参数可在脚本中通过 `$1`、`$2`、`$@` 读取；执行前会校验目标主机已存在 ShellX `known_hosts` 信任记录；默认最多同时执行 6 个会话，单会话输出最多保留最后 128 KiB，默认超时 3600 秒，超时或手动终止后会结束对应 SSH 子进程

## 已知限制

- 当前 `lrzsz` 依赖本机存在 `sz` / `rz` 命令，常见安装方式是 `brew install lrzsz`
- 当前版本已移除 `lrzsz` 传输时固定 `4 KiB` 缓冲限制，局域网场景会改用工具默认协商参数以避免异常低速
- 当前已增强 `tmux` / 包装 shell 命令下的方向识别与多文件上传；目录上传/下载仍建议优先使用右键菜单中的 SFTP
- 当前 SFTP 下载尚未提供远端文件树浏览，下载文件或文件夹时需要手动输入远端路径
- 当前本机终端默认优先使用 `/bin/zsh` 作为交互式非 login shell 启动；若目标机器不存在该路径，会自动退回用户环境中的 `SHELL` 或 `/bin/bash`
- 当前 `known_hosts` 由 ShellX 单独管理在 `Application Support/ShellX/known_hosts`，不会直接写入用户 `~/.ssh/known_hosts`
- 当前 host key 确认依赖 `ssh-keyscan` 预扫描结果；应用会显式尝试拉取 `ed25519/ecdsa/rsa` 多种 host key 算法。若目标端口在 SSH 握手阶段直接断开或网络环境限制扫描返回，未知主机会继续展示底层 `ssh-keyscan` 输出；已存在 ShellX `known_hosts` 记录的主机会在扫描失败时回退到 OpenSSH 严格校验，实际 SSH/SFTP 连接仍使用 `StrictHostKeyChecking=yes`
- 当前 SSH 会尝试通过 `SendEnv/SetEnv` 向远端发送 `LANG` / `LC_CTYPE`；若服务器禁用了 `AcceptEnv`，ShellX 只能保证本地 `ssh` 客户端保持 UTF-8，无法强制远端 shell 切换 locale
- 当前账号密码模式下，ShellX 会在远端真正提示密码时再尝试读取系统 Keychain 并自动回填；若读取不到，才会提示输入一次，并在开启保存到系统 Keychain 时重新写入
- 当前批量脚本执行仅支持 SSH Agent 和私钥认证会话；账号密码认证会话会在执行结果中直接标记失败，避免批量任务阻塞在交互式密码输入
- 当前批量脚本执行是非交互模式，不适合 `top`、`vim`、二次确认输入等需要 TTY 或持续交互的命令
- 历史 `scripts.json` 中缺少脚本语言字段的记录会按 Shell 语法读取；保存脚本后会写入新的 `language` 字段
- 当前更新功能只接受 GitHub Release 中可通过 SHA256 校验的 `.dmg` 或 `.zip` 安装资产，并从中查找 `ShellX.app` 替换当前运行的 `.app`；不会执行 Release 包内自带脚本。若当前应用安装目录不可写，点击“立即重启”安装时会失败，需要手动安装下载的 Release 资产
- 当前自动更新只负责后台下载更新包，不会在下载完成后直接重启；用户点击“立即重启”后才会退出当前进程、替换 `.app` 并重新打开
- 若在会话编辑页启用了“将密码保存到系统 Keychain”并填写了新密码，保存时会立即创建或刷新 `com.shellx.session-password` 条目；若留空保存，则不会覆盖当前已保存密码
- 历史 `sessions.json` 中的 `notes` 字段会在读取时自动迁移为单个标签，并在下次保存后统一写回新的 `tags` 数组结构
- 单次 SSH 连接生命周期内，ShellX 只会尝试一次 Keychain 自动填充；若自动回填后远端仍再次提示密码，可通过“复制调试”查看是否已经真正把密码写入 SSH PTY
- 当前环境缺少 `swift` / `xcodebuild`，本次提交未执行本地编译和测试，只完成了工程与代码落地

## 本地打开方式

1. 使用 Xcode 打开 `ShellX.xcodeproj`
2. 选择 `ShellX` Scheme
3. 运行 macOS App

## 生成 DMG 安装包

如果你希望生成的 `.dmg` 保留当前工程的签名身份（例如让 Keychain 尽量把 DMG 中的 `.app` 视为与 Xcode 运行版本相同的应用主体），可以直接使用仓库内脚本：

```bash
./scripts/build-dmg.sh
```

默认行为：

- 使用 `ShellX` Scheme
- 使用 `Release` 配置构建
- 保留工程当前签名配置进行构建
- 输出到项目根目录下的 `dist/`
- 生成 `dist/ShellX-Release.dmg`

常见用法：

```bash
./scripts/build-dmg.sh --configuration Debug
./scripts/build-dmg.sh --output-dir ./artifacts
./scripts/build-dmg.sh --volume-name "ShellX Installer"
./scripts/build-dmg.sh --unsigned
```

注意事项：

- 脚本依赖系统已安装 `xcodebuild` 和 `hdiutil`
- 默认会保留工程当前签名配置；如果你的目标是复用本机已有的 Keychain 信任关系，不要使用 `--unsigned`
- 只有显式传入 `--unsigned` 时，脚本才会生成未签名安装包；这种产物在其他 Mac 上打开时可能需要右键“打开”或在系统设置中手动放行
- 若后续需要对外分发，仍建议补充正式签名和公证流程

## 发布 GitHub Release

推送形如 `v0.2.0` 的 tag 后，GitHub Actions 会自动执行 `.github/workflows/release.yml`，复用 `scripts/build-dmg.sh --unsigned` 构建未签名的 `dist/ShellX-Release.dmg` 和 `dist/ShellX-Release.dmg.sha256`，然后创建同名稳定 Release 资产。Release 说明会按“上一个版本 tag → 当前 tag”动态写入每个 commit 的标题和短 hash，不写入固定安装说明。应用内更新检查只读取最新稳定 Release，因此不要把正式更新包发布为 draft 或 prerelease。

发布前需要同步更新 Xcode 工程中的 `MARKETING_VERSION`，并让 tag 去掉前缀 `v` 后与应用版本完全一致；workflow 会自动校验，不一致会直接失败。例如发布 `MARKETING_VERSION = 0.2.0` 时使用：

```bash
./scripts/set-marketing-version.sh 0.2.0
git tag v0.2.0
git push origin v0.2.0
```

自动 Release workflow 仅授予 `contents: write` 权限，用于创建 Release 和上传 DMG；当前未签名发布不需要配置 Apple Developer 账号、证书、notarization 或 GitHub Actions Secrets。未签名 DMG 在其他 Mac 上首次打开时可能需要右键“打开”或在系统设置中手动放行。

如果 macOS 提示“ShellX.app 已损坏，无法打开”，通常是未签名应用被 Gatekeeper 隔离。请先把 `ShellX.app` 拖到 `/Applications`，然后执行：

```bash
sudo codesign --force --deep --sign - /Applications/ShellX.app
sudo xattr -dr com.apple.quarantine /Applications/ShellX.app
open /Applications/ShellX.app
```

应用内自动更新安装新版本后，也会尝试用当前用户权限自动执行等价的 ad-hoc 重签名和隔离属性清理；由于 GUI 应用无法交互式输入 `sudo` 密码，如果系统仍然拦截，请手动执行上面的命令。

如果执行上面的命令后仍然提示“ShellX.app 已损坏，无法打开”，再手动清理所有扩展属性作为兜底：

```bash
sudo xattr -cr /Applications/ShellX.app
open /Applications/ShellX.app
```

如果 macOS 提示“应用程序无法打开。-50”，先确认 `.app` bundle 没有在安装或更新时损坏：

```bash
test -f /Applications/ShellX.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' /Applications/ShellX.app/Contents/Info.plist
ls -l /Applications/ShellX.app/Contents/MacOS/
```

若 `Info.plist` 或 `Contents/MacOS/ShellX` 缺失，请重新从 dmg 拖拽安装；若文件存在但仍打不开，再执行上面的 `codesign` 和 `xattr` 修复命令。

如果只想先做最小放行，也可以只移除隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/ShellX.app
open /Applications/ShellX.app
```

如果后续要提供正式签名和公证的 DMG，需要先加入 Apple Developer Program，再补充 Developer ID Application 证书、notarization 凭据和对应的 GitHub Actions Secrets。

PR 和 `main` 分支推送会执行 `.github/workflows/ci.yml`，校验 `MARKETING_VERSION` 格式并运行未签名 macOS Debug 构建，用于提前发现 Swift 编译、包解析和工程配置问题。

## 稳定签名与 Keychain

- 如果你希望账号密码会话在首次保存到系统 Keychain 后，后续重启 ShellX 也尽量直接读取，不要每次都重新要求授权，必须使用稳定的应用签名身份。
- 当前工程已经将关键签名配置外置到 [Config/ShellX-Signing.xcconfig](/home/dylan/project/shellx/Config/ShellX-Signing.xcconfig)，仓库默认使用 ad-hoc 签名，避免没有 Apple Developer 账号或本机 profile 时无法构建。
- 主 target 已显式接入 [Config/ShellX.entitlements](/home/dylan/project/shellx/Config/ShellX.entitlements)，声明当前应用自己的 `keychain-access-groups`，用于避免某些本地调试签名环境下调用 Keychain API 时返回 “A required entitlement isn't present”。
- 如需使用自己的稳定签名，请创建不会提交到 Git 的 `Config/ShellX-Signing.local.xcconfig`，至少覆盖两项：
  - `DEVELOPMENT_TEAM = 你的 Team ID`
  - `PRODUCT_BUNDLE_IDENTIFIER = 你自己的稳定 Bundle Identifier`
- 如果你要让 Xcode 自动管理 profile，可在本地文件中同时设置 `CODE_SIGN_STYLE = Automatic`；仓库默认值不会绑定任何个人 Team 或 profile。
- 推荐验证步骤：
  1. 填好本地签名文件后，在 Xcode 里重新构建并运行 ShellX。
  2. 用这份稳定签名的构建重新连接一次账号密码会话，并允许它写入 Keychain。
  3. 完全退出 ShellX，再重新打开并连接同一会话。
  4. 观察是否已经不再重复要求输入 mac 登录密码。
- 如果之前已经用临时调试构建保存过密码，建议在稳定签名版本中重新输入并保存一次，让 Keychain 条目和新的应用身份重新建立信任。

## 后续演进建议

- 用 `SwiftNIO SSH` 或 `libssh2` 替换系统 `ssh` 进程桥接
- 将会话配置迁移到 `SQLite`
- 接入 `~/.ssh/config` 导入和 `known_hosts` 可视化确认
- 继续补强 `lrzsz` 目录级传输体验与更多终端复用场景兼容性

## 兼容性说明

- 当前持久化文件为 `Application Support/ShellX/sessions.json`
- 账号密码不写入 `sessions.json`；若启用 Keychain 保存，SSH 与 SFTP 在真正需要密码时都会优先复用 Keychain 中的密码；若关闭保存或切换为非密码认证，会同步删除对应 Keychain 条目
- 旧版本写入的数据保护 Keychain 条目会在首次成功读取时自动迁移到标准登录 Keychain，迁移完成后后续重新启动应用时应优先直接读取
- 若后续切换为数据库存储，需要提供从 JSON 到数据库的迁移逻辑
- 当前认证配置中的 `privateKeyPath` 为本地文件路径；若后续接入沙箱分发，需迁移为安全范围书签
- 本次新增 `passwordStoredInKeychain` 字段用于标记会话是否托管密码，旧版本 `sessions.json` 缺少该字段时会自动回填为 `false`
- 本次将会话自由文本备注调整为 `tags` 数组结构；读取旧数据时会自动把 `notes` 作为单个标签迁移，保存后将不再继续写出旧 `notes` 字段
- 本次新增 `Config/ShellX.entitlements` 并将其接入主 target；这属于签名/权限配置变更。若你本地仍沿用旧构建产物，请先清理构建目录并重新运行，再验证 Keychain 保存与读取行为
- 当前工程新增 `SwiftTerm` Swift Package 依赖；首次在 Xcode 打开工程时会自动解析远程包
- 本次新增的全局配置保存在应用级 `UserDefaults` 中，不写入 `sessions.json`，也不影响已有会话配置结构
- 本次新增的主窗口标签页恢复开关同样保存在应用级 `UserDefaults` 中；默认开启以兼容既有主窗口重开行为，关闭后只影响后续关闭主窗口时的终端标签生命周期
- 本次新增的脚本库保存在 `Application Support/ShellX/scripts.json`，不写入 `sessions.json`，因此不会改变已有会话配置结构
- 本次新增的脚本大窗口编辑入口仅复用当前脚本草稿，不新增持久化字段；终端输入后自动回到底部只调整当前视图滚动状态，不改变 SSH 会话、脚本库或全局配置结构
- 本次新增的自动更新开关同样保存在应用级 `UserDefaults` 中；更新检查依赖 GitHub Release API 和 `dylan120/shellx` 仓库的最新稳定 Release，不读取 draft 或 prerelease
- 应用版本由 Xcode 工程中的 `MARKETING_VERSION` 提供；发版时应同步更新版本号，并推送形如 `v0.2.0` 的 tag 自动创建 GitHub Release
