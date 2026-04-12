# ShellX

ShellX 是一个面向 macOS 的原生 SSH 会话管理工具，重点解决以下问题：

- 通过文件夹树组织和管理 SSH 会话
- 在独立的会话管理窗口中完成新增、编辑、搜索、复制和删除
- 从管理窗口直接打开 SSH 控制台窗口

## 当前实现范围

本仓库当前提供一版可直接在 Xcode 中打开的 MVP 工程，包含：

- 原生 `SwiftUI` macOS App 工程骨架
- 本地 JSON 持久化的文件夹树和 SSH 会话配置
- 会话管理窗口：文件夹树、会话列表、详情面板、搜索、编辑
- 基于 `SwiftTerm` + 自管 PTY + 系统 `/usr/bin/ssh` 的终端窗口，可运行交互式 SSH 会话和常见 TUI 程序
- 终端支持基础 `lrzsz` 触发：远端 `rz` 时可选本地文件上传，远端 `sz` 时可选本地目录接收
- 连接前支持 ShellX 自己的 `known_hosts` 首次确认，私钥模式支持复用 macOS/OpenSSH `UseKeychain`

## 关键假设

- 当前版本是本地单用户桌面应用，不涉及云同步或多人协作
- 当前版本优先支持 `SSH Agent` 和私钥认证
- 当前终端窗口基于 `SwiftTerm`，优先提供接近原生终端的交互体验

## 功能说明

### 会话管理

- 支持新建顶级文件夹和子文件夹
- 支持按文件夹树筛选会话
- 支持新建、编辑、复制、删除 SSH 会话
- 支持按会话名称、主机、用户名搜索

### SSH 连接

- 支持配置主机、端口、用户名、私钥文件、启动后预执行命令
- 连接时调用系统 `ssh` 命令，参数由会话配置拼装
- 终端窗口支持键盘输入、ANSI/TUI 渲染、断开连接、重连
- 支持基础 `lrzsz` 双向文件传输触发
- 首次连接未知主机时展示 host key 指纹确认；私钥模式可启用 Keychain 集成

## 已知限制

- 当前 `lrzsz` 依赖本机存在 `sz` / `rz` 命令，常见安装方式是 `brew install lrzsz`
- 当前仅保证直连 SSH 会话下的基础单文件 `lrzsz` 流程，不保证 `tmux`、`screen`、多跳或目录传输
- 当前 `known_hosts` 由 ShellX 单独管理在 `Application Support/ShellX/known_hosts`，不会直接写入用户 `~/.ssh/known_hosts`
- 当前仅对首次未知主机提供确认；检测到 host key 变更时会直接阻断，不提供覆盖写入
- 当前 Keychain 集成依赖 macOS OpenSSH 的 `UseKeychain` / `AddKeysToAgent`，主要面向私钥口令管理，不包含密码自动登录
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
- 若后续切换为数据库存储，需要提供从 JSON 到数据库的迁移逻辑
- 当前认证配置中的 `privateKeyPath` 为本地文件路径；若后续接入沙箱分发，需迁移为安全范围书签
- 当前工程新增 `SwiftTerm` Swift Package 依赖；首次在 Xcode 打开工程时会自动解析远程包
