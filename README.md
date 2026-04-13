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
- 本地 JSON 持久化的文件夹树和 SSH 会话配置
- 会话管理窗口：左侧文件夹/会话树、详情面板、搜索、编辑
- 基于 `SwiftTerm` + 自管 PTY + 系统 `/usr/bin/ssh` 的内嵌终端标签页，可运行交互式 SSH 会话和常见 TUI 程序
- 终端支持基础 `lrzsz` 触发：远端 `rz` 时可选本地文件上传，远端 `sz` 时可选本地目录接收
- 当前活跃 SSH 会话支持通过系统 `/usr/bin/sftp` 发起文件和文件夹上传/下载
- 连接前支持 ShellX 自己的 `known_hosts` 首次确认，私钥模式支持复用 macOS/OpenSSH `UseKeychain`
- 支持账号密码认证；当远端真正提示密码时，ShellX 会优先从系统 Keychain 读取并自动回填，未命中时再提示输入一次

## 关键假设

- 当前版本是本地单用户桌面应用，不涉及云同步或多人协作
- 当前版本优先支持 `SSH Agent`、私钥和账号密码认证
- 当前终端窗口基于 `SwiftTerm`，优先提供接近原生终端的交互体验

## 功能说明

### 会话管理

- 支持新建顶级文件夹和子文件夹
- 支持在左侧文件夹菜单中直接在当前文件夹下新建会话
- 支持在左侧文件夹树中直接展开查看会话，并按文件夹树筛选会话
- 支持在左侧“全部会话”树中拖动会话或文件夹到其他文件夹；拖到“全部会话”可移回根层级
- 支持新建、编辑、复制、删除 SSH 会话
- 支持按会话名称、主机、用户名搜索

### SSH 连接

- 支持配置主机、端口、用户名、私钥文件、启动后预执行命令
- 私钥认证模式下，会话编辑页通过本机文件选择窗口选取私钥文件，不需要手动填写路径
- 账号密码认证模式下，可在会话编辑页重新设置登录密码；保存时会立即新建或刷新系统 Keychain 条目，留空保存则保持现有已保存密码不变
- 连接时调用系统 `ssh` 命令，参数由会话配置拼装；主机指纹校验以前置 `ssh-keyscan` 预检查与 ShellX 确认结果为准
- 终端标签页支持键盘输入、ANSI/TUI 渲染、断开连接、重连
- 默认会先打开一个“本机终端”标签；你仍可继续从左侧会话树打开 SSH 标签，并在顶部标签栏间切换
- 同一个 SSH 会话支持同时打开多个独立标签；每个标签都会维护自己独立的终端实例和连接状态
- 顶部标签支持拖动自由排序
- 终端标签操作位于顶部栏，通过右击标签菜单执行切换、复制到新标签、重连、断开、复制调试、清空调试和关闭
- “复制调试”会同时带出密码存储访问日志和 SSH 密码自动填充事件，可用于判断远端密码提示后是否真的读取了 Keychain、以及密码是否实际写入了 SSH PTY
- 当前会话状态、主机地址与工作目录展示位于终端底部栏，减少顶部操作干扰
- 终端底部的普通状态提示会自动消失；只有连接失败等真实错误才会继续保留为错误信息，并提供“复制错误”
- 支持基础 `lrzsz` 双向文件传输触发
- 当前已连接标签支持通过右击标签菜单发起 `SFTP 上传文件/文件夹`、`SFTP 下载文件` 和 `SFTP 下载文件夹`
- 首次连接未知主机、主机指纹变更或服务器新增 host key 算法时都会展示指纹确认；私钥模式可启用 Keychain 集成；账号密码模式下会在远端真正提示密码时再尝试读取 Keychain 并自动回填

## 已知限制

- 当前 `lrzsz` 依赖本机存在 `sz` / `rz` 命令，常见安装方式是 `brew install lrzsz`
- 当前仅保证直连 SSH 会话下的基础单文件 `lrzsz` 流程，不保证 `tmux`、`screen`、多跳或目录传输
- 当前 SFTP 下载尚未提供远端文件树浏览，下载文件或文件夹时需要手动输入远端路径
- 当前本机终端默认尝试使用 `/bin/zsh -l` 启动；若目标机器不存在该路径，会自动退回用户环境中的 `SHELL` 或 `/bin/bash`
- 当前 `known_hosts` 由 ShellX 单独管理在 `Application Support/ShellX/known_hosts`，不会直接写入用户 `~/.ssh/known_hosts`
- 当前 host key 确认依赖 `ssh-keyscan` 预扫描结果；应用会显式尝试拉取 `ed25519/ecdsa/rsa` 多种 host key 算法，但若网络环境限制了扫描返回，仍可能需要手动清理应用内 `known_hosts` 后重试
- 当前账号密码模式下，ShellX 会在远端真正提示密码时再尝试读取系统 Keychain 并自动回填；若读取不到，才会提示输入一次，并在开启保存到系统 Keychain 时重新写入
- 若在会话编辑页启用了“将密码保存到系统 Keychain”并填写了新密码，保存时会立即创建或刷新 `com.shellx.session-password` 条目；若留空保存，则不会覆盖当前已保存密码
- 单次 SSH 连接生命周期内，ShellX 只会尝试一次 Keychain 自动填充；若自动回填后远端仍再次提示密码，可通过“复制调试”查看是否已经真正把密码写入 SSH PTY
- 当前环境缺少 `swift` / `xcodebuild`，本次提交未执行本地编译和测试，只完成了工程与代码落地

## 本地打开方式

1. 使用 Xcode 打开 `ShellX.xcodeproj`
2. 选择 `ShellX` Scheme
3. 运行 macOS App

## 生成 DMG 安装包

如果只考虑本机测试或内部分发，不考虑签名、公证和 Gatekeeper 放行，可以直接使用仓库内脚本生成未签名的 `.app` 和 `.dmg`：

```bash
./scripts/build-dmg.sh
```

默认行为：

- 使用 `ShellX` Scheme
- 使用 `Release` 配置构建
- 不进行代码签名
- 输出到项目根目录下的 `dist/`
- 生成 `dist/ShellX-Release.dmg`

常见用法：

```bash
./scripts/build-dmg.sh --configuration Debug
./scripts/build-dmg.sh --output-dir ./artifacts
./scripts/build-dmg.sh --volume-name "ShellX Installer"
```

注意事项：

- 脚本依赖系统已安装 `xcodebuild` 和 `hdiutil`
- 当前生成的是未签名安装包，其他 Mac 上打开时可能需要右键“打开”或在系统设置中手动放行
- 若后续需要对外分发，仍建议补充正式签名和公证流程

## 稳定签名与 Keychain

- 如果你希望账号密码会话在首次保存到系统 Keychain 后，后续重启 ShellX 也尽量直接读取，不要每次都重新要求授权，必须使用稳定的应用签名身份。
- 当前工程已经将关键签名配置外置到 [Config/ShellX-Signing.xcconfig](/home/dylan/project/shellx/Config/ShellX-Signing.xcconfig)。
- 你至少需要填写两项：
  - `DEVELOPMENT_TEAM = 你的 Team ID`
  - `PRODUCT_BUNDLE_IDENTIFIER = 你自己的稳定 Bundle Identifier`
- 推荐验证步骤：
  1. 填好上述两个值后，在 Xcode 里重新构建并运行 ShellX。
  2. 用这份稳定签名的构建重新连接一次账号密码会话，并允许它写入 Keychain。
  3. 完全退出 ShellX，再重新打开并连接同一会话。
  4. 观察是否已经不再重复要求输入 mac 登录密码。
- 如果之前已经用临时调试构建保存过密码，建议在稳定签名版本中重新输入并保存一次，让 Keychain 条目和新的应用身份重新建立信任。

## 后续演进建议

- 用 `SwiftNIO SSH` 或 `libssh2` 替换系统 `ssh` 进程桥接
- 将会话配置迁移到 `SQLite`
- 接入 `~/.ssh/config` 导入和 `known_hosts` 可视化确认
- 增加 `lrzsz` 进度展示、多文件传输与 `tmux` 兼容增强

## 兼容性说明

- 当前持久化文件为 `Application Support/ShellX/sessions.json`
- 账号密码不写入 `sessions.json`；若启用 Keychain 保存，SSH 与 SFTP 在真正需要密码时都会优先复用 Keychain 中的密码；若关闭保存或切换为非密码认证，会同步删除对应 Keychain 条目
- 旧版本写入的数据保护 Keychain 条目会在首次成功读取时自动迁移到标准登录 Keychain，迁移完成后后续重新启动应用时应优先直接读取
- 若后续切换为数据库存储，需要提供从 JSON 到数据库的迁移逻辑
- 当前认证配置中的 `privateKeyPath` 为本地文件路径；若后续接入沙箱分发，需迁移为安全范围书签
- 本次新增 `passwordStoredInKeychain` 字段用于标记会话是否托管密码，旧版本 `sessions.json` 缺少该字段时会自动回填为 `false`
- 当前工程新增 `SwiftTerm` Swift Package 依赖；首次在 Xcode 打开工程时会自动解析远程包
