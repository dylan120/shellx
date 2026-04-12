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
- 本地 JSON 持久化的文件夹树和 SSH 会话配置
- 会话管理窗口：左侧文件夹/会话树、详情面板、搜索、编辑
- 基于 `SwiftTerm` + 自管 PTY + 系统 `/usr/bin/ssh` 的内嵌终端标签页，可运行交互式 SSH 会话和常见 TUI 程序
- 终端支持基础 `lrzsz` 触发：远端 `rz` 时可选本地文件上传，远端 `sz` 时可选本地目录接收
- 当前活跃 SSH 会话支持通过系统 `/usr/bin/sftp` 发起文件和文件夹上传/下载
- 连接前支持 ShellX 自己的 `known_hosts` 首次确认，私钥模式支持复用 macOS/OpenSSH `UseKeychain`
- 支持账号密码认证，可选择在首次连接成功前输入一次密码并保存到系统 Keychain；若不保存或 Keychain 不可用，连接时可临时输入本次密码

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
- 连接时调用系统 `ssh` 命令，参数由会话配置拼装；主机指纹校验以前置 `ssh-keyscan` 预检查与 ShellX 确认结果为准
- 终端标签页支持键盘输入、ANSI/TUI 渲染、断开连接、重连
- 终端标签操作位于顶部栏，通过右击标签菜单执行切换、重连、断开、复制调试、清空调试和关闭
- 当前会话状态、主机地址与工作目录展示位于终端底部栏，减少顶部操作干扰
- 支持基础 `lrzsz` 双向文件传输触发
- 当前已连接标签支持通过右击标签菜单发起 `SFTP 上传文件/文件夹`、`SFTP 下载文件` 和 `SFTP 下载文件夹`
- 首次连接未知主机、主机指纹变更或服务器新增 host key 算法时都会展示指纹确认；私钥模式可启用 Keychain 集成；密码模式在首次连接时输入一次后可写入系统 Keychain，后续连接优先自动读取

## 已知限制

- 当前 `lrzsz` 依赖本机存在 `sz` / `rz` 命令，常见安装方式是 `brew install lrzsz`
- 当前仅保证直连 SSH 会话下的基础单文件 `lrzsz` 流程，不保证 `tmux`、`screen`、多跳或目录传输
- 当前 SFTP 下载尚未提供远端文件树浏览，下载文件或文件夹时需要手动输入远端路径
- 当前 `known_hosts` 由 ShellX 单独管理在 `Application Support/ShellX/known_hosts`，不会直接写入用户 `~/.ssh/known_hosts`
- 当前 host key 确认依赖 `ssh-keyscan` 预扫描结果；应用会显式尝试拉取 `ed25519/ecdsa/rsa` 多种 host key 算法，但若网络环境限制了扫描返回，仍可能需要手动清理应用内 `known_hosts` 后重试
- 当前密码模式基于系统 `ssh` 进程的交互式密码提示自动注入，仅覆盖标准 `password:` 提示；遇到自定义 challenge 或多因素认证场景时，可能仍需手动参与
- 当前环境缺少 `swift` / `xcodebuild`，本次提交未执行本地编译和测试，只完成了工程与代码落地

## 本地打开方式

1. 使用 Xcode 打开 `ShellX.xcodeproj`
2. 选择 `ShellX` Scheme
3. 运行 macOS App

## 后续演进建议

- 用 `SwiftNIO SSH` 或 `libssh2` 替换系统 `ssh` 进程桥接
- 将会话配置迁移到 `SQLite`
- 接入 `~/.ssh/config` 导入和 `known_hosts` 可视化确认
- 增加 `lrzsz` 进度展示、多文件传输与 `tmux` 兼容增强

## 兼容性说明

- 当前持久化文件为 `Application Support/ShellX/sessions.json`
- 账号密码不写入 `sessions.json`；若启用 Keychain 保存，会在首次连接输入密码后写入 macOS Keychain，若关闭保存或切换为非密码认证，会同步删除对应 Keychain 条目
- 若后续切换为数据库存储，需要提供从 JSON 到数据库的迁移逻辑
- 当前认证配置中的 `privateKeyPath` 为本地文件路径；若后续接入沙箱分发，需迁移为安全范围书签
- 本次新增 `passwordStoredInKeychain` 字段用于标记会话是否托管密码，旧版本 `sessions.json` 缺少该字段时会自动回填为 `false`
- 当前工程新增 `SwiftTerm` Swift Package 依赖；首次在 Xcode 打开工程时会自动解析远程包
