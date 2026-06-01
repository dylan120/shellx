# SSH 远端网络出口设计说明

## 目标

远端网络出口用于解决服务器无法直接访问外网，但当前 Mac 可以通过本地网络或本地代理访问外网的场景。用户在 SSH 会话中启用该功能后，服务器上的进程可以通过服务器本机的代理地址访问外部服务。

## 实现方式

ShellX 继续复用系统 `/usr/bin/ssh`，不在应用内实现代理协议。

本机网络出口模式会追加：

```bash
-o ExitOnForwardFailure=yes -R 127.0.0.1:1080
```

OpenSSH 在未指定远端目标地址时，会把 `-R` 作为远端动态转发处理，在服务器侧提供 SOCKS5 入口。外网连接由本地 ssh 客户端发起，因此出口网络等同于当前 Mac 的网络环境。

本机已有代理模式会追加：

```bash
-o ExitOnForwardFailure=yes -R 127.0.0.1:18080:127.0.0.1:7890
```

服务器访问 `127.0.0.1:18080` 时，连接会被转发到当前 Mac 的 `127.0.0.1:7890`。远端使用 HTTP 还是 SOCKS5 取决于本机代理实际协议。

## 配置字段

会话配置新增 `remoteNetworkForwarding`：

```json
{
  "isEnabled": true,
  "mode": "dynamicSOCKS",
  "bindAddress": "127.0.0.1",
  "port": 1080,
  "localProxyHost": "127.0.0.1",
  "localProxyPort": 7890,
  "remoteProxyScheme": "socks5h",
  "setProxyEnvironment": true
}
```

- `isEnabled`：是否启用远端动态转发。
- `mode`：`dynamicSOCKS` 表示通过当前 Mac 的网络出口发起外网连接，`localProxy` 表示转发到当前 Mac 上已有的代理服务。
- `bindAddress`：服务器侧监听地址，默认 `127.0.0.1`。
- `port`：服务器侧监听端口，默认 `1080`。
- `localProxyHost`：本机已有代理模式下的 Mac 侧代理监听地址。
- `localProxyPort`：本机已有代理模式下的 Mac 侧代理监听端口。
- `remoteProxyScheme`：远端命令应使用的代理协议，支持 `socks5h` 和 `http`。
- `setProxyEnvironment`：连接后是否设置 `ALL_PROXY`、`HTTPS_PROXY` 和 `HTTP_PROXY`。

旧版本 `sessions.json` 缺少该字段时会自动回填为关闭状态。

## 安全边界

默认监听 `127.0.0.1`，只允许服务器本机进程访问代理入口。若用户改为 `0.0.0.0` 或 `*`，代理入口可能暴露给服务器所在网络内的其他主机，应先确认服务器防火墙和账号权限。

ShellX 会限制监听地址只能包含主机名、IPv4、`*`、点、横线或下划线，避免把异常字符交给 OpenSSH 解析。该功能不保存代理凭据，也不会改变 Keychain 中的 SSH 密码处理方式。

## 运维与排障

本机网络出口模式可在服务器侧用以下命令验证：

```bash
curl --proxy socks5h://127.0.0.1:1080 https://example.com
```

本机已有代理模式应按本机代理协议验证，例如 HTTP 代理：

```bash
curl --proxy http://127.0.0.1:18080 https://example.com
```

如果开启了自动环境变量，可直接执行依赖 `ALL_PROXY`、`HTTPS_PROXY` 或 `HTTP_PROXY` 的命令。若连接立即失败，优先检查远端 `sshd_config` 是否允许 TCP 转发，例如 `AllowTcpForwarding` 和相关账号策略。

该功能只影响交互式 SSH 会话，不影响 SFTP 上传下载和批量脚本执行。
