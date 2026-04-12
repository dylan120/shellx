import AppKit
import Foundation
import SwiftTerm

enum TerminalConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected
    case failed(String)

    var displayText: String {
        switch self {
        case .idle:
            return "未启动"
        case .connecting:
            return "连接中"
        case .connected:
            return "运行中"
        case .disconnected:
            return "已断开"
        case .failed(let message):
            return "已退出：\(message)"
        }
    }
}

struct SSHPasswordPrompt: Identifiable, Equatable {
    let id = UUID()
    let sessionName: String
    let message: String
}

@MainActor
final class TerminalSessionViewModel: NSObject, ObservableObject, TerminalViewDelegate, SSHPTYTransportDelegate {
    @Published var connectionState: TerminalConnectionState = .idle
    @Published var terminalTitle = "SSH 控制台"
    @Published var workingDirectory: String?
    @Published var lastExitMessage: String?
    @Published var transferState: ZModemTransferState = .idle
    @Published var hostKeyPrompt: KnownHostPrompt?
    @Published var passwordPrompt: SSHPasswordPrompt?

    private weak var terminalView: TerminalView?
    private let transport = SSHPTYTransport()
    private let knownHostsService = KnownHostsService()
    private let passwordStore = SessionPasswordStore()
    private var startedSessionID: UUID?
    private var pendingSession: SSHSessionProfile?
    private var pendingConnectedHandler: ((UUID) -> Void)?

    override init() {
        super.init()
        transport.delegate = self
    }

    func attachTerminalView(_ terminalView: TerminalView) {
        self.terminalView = terminalView
        terminalView.terminalDelegate = self
        configureAppearance(for: terminalView)

        if let pendingSession, let pendingConnectedHandler {
            self.pendingSession = nil
            self.pendingConnectedHandler = nil
            start(session: pendingSession, onConnected: pendingConnectedHandler)
        }
    }

    func reconnect(session: SSHSessionProfile, onConnected: @escaping (UUID) -> Void) {
        terminate()
        start(session: session, onConnected: onConnected)
    }

    func terminate() {
        transport.terminate()
        if case .connected = connectionState {
            connectionState = .disconnected
        }
        transferState = .idle
        hostKeyPrompt = nil
    }

    static func sshArguments(
        for session: SSHSessionProfile,
        userKnownHostsPath: String,
        strictHostKeyChecking: String = "no"
    ) -> [String] {
        var args = [
            "-tt",
            "-p", "\(session.port)",
            "-o", "UserKnownHostsFile=\(userKnownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=\(strictHostKeyChecking)",
            "-o", "UpdateHostKeys=no"
        ]
        if session.authMethod == .privateKey {
            let privateKeyPath = session.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !privateKeyPath.isEmpty {
                args.append(contentsOf: ["-i", (privateKeyPath as NSString).expandingTildeInPath])
            }
            if session.useKeychainForPrivateKey {
                args.append(contentsOf: ["-o", "UseKeychain=yes", "-o", "AddKeysToAgent=yes"])
            }
        } else if session.authMethod == .password {
            args.append(contentsOf: [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ])
        }
        args.append(session.destination)
        if !session.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(session.startupCommand)
        }
        return args
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        transport.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        terminalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "SSH 控制台" : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        workingDirectory = directory
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        transport.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
    }

    func transportDidReceive(_ data: Data) {
        terminalView?.feed(byteArray: Array(data)[...])
    }

    func transportDidTerminate(exitCode: Int32?) {
        startedSessionID = nil
        workingDirectory = nil
        transferState = .idle
        hostKeyPrompt = nil

        guard let exitCode else {
            connectionState = .failed("终端进程异常结束")
            lastExitMessage = "终端进程异常结束"
            return
        }

        if exitCode == 0 {
            connectionState = .disconnected
            lastExitMessage = "SSH 会话已正常关闭"
        } else {
            let message = "退出码 \(exitCode)"
            connectionState = .failed(message)
            lastExitMessage = message
        }
    }

    func transportDidDetectZModem(_ trigger: ZModemTrigger) {
        switch trigger {
        case .uploadRequest:
            transferState = .preparing(.uploadToRemote)
            handleUploadTrigger()
        case .downloadRequest:
            transferState = .preparing(.downloadFromRemote)
            handleDownloadTrigger()
        }
    }

    func transportDidFail(_ message: String) {
        if message.contains("完成") {
            transferState = .completed(message)
        } else {
            transferState = .failed(message)
        }
        lastExitMessage = message
    }

    func trustCurrentHostAndContinue() {
        guard let hostKeyPrompt, let pendingSession, let pendingConnectedHandler else { return }
        Task {
            do {
                let temporaryKnownHostsPath = try KnownHostsService.temporaryKnownHostsFilePath(for: hostKeyPrompt)
                try await knownHostsService.trust(hostKeyPrompt)
                await MainActor.run {
                    self.hostKeyPrompt = nil
                    self.lastExitMessage = "主机指纹已写入 ShellX 的 known_hosts，正在继续连接。"
                    self.connectionState = .connecting
                    self.pendingSession = nil
                    self.pendingConnectedHandler = nil
                    self.startTransport(
                        session: pendingSession,
                        onConnected: pendingConnectedHandler,
                        knownHostsPathOverride: temporaryKnownHostsPath,
                        strictHostKeyCheckingOverride: "no"
                    )
                }
            } catch {
                await MainActor.run {
                    self.connectionState = .failed("写入 known_hosts 失败：\(error.localizedDescription)")
                    self.hostKeyPrompt = nil
                }
            }
        }
    }

    func cancelHostTrust() {
        hostKeyPrompt = nil
        pendingSession = nil
        pendingConnectedHandler = nil
        connectionState = .failed("已取消主机指纹确认")
    }

    func submitPasswordAndContinue(_ password: String) {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty,
              let pendingSession,
              let pendingConnectedHandler else { return }

        passwordPrompt = nil
        lastExitMessage = "正在使用本次输入的密码继续连接。"
        connectionState = .connecting
        self.pendingSession = nil
        self.pendingConnectedHandler = nil
        startTransport(session: pendingSession, onConnected: pendingConnectedHandler, passwordOverride: trimmedPassword)
    }

    func cancelPasswordPrompt() {
        passwordPrompt = nil
        pendingSession = nil
        pendingConnectedHandler = nil
        connectionState = .failed("已取消密码输入")
    }

    private func start(session: SSHSessionProfile, onConnected: @escaping (UUID) -> Void) {
        guard terminalView != nil else {
            pendingSession = session
            pendingConnectedHandler = onConnected
            connectionState = .connecting
            return
        }

        startedSessionID = session.id
        terminalTitle = session.name
        workingDirectory = nil
        lastExitMessage = nil
        transferState = .idle
        connectionState = .connecting
        pendingSession = nil
        pendingConnectedHandler = nil
        hostKeyPrompt = nil

        Task {
            await prepareAndStart(session: session, onConnected: onConnected)
        }
    }

    private func prepareAndStart(session: SSHSessionProfile, onConnected: @escaping (UUID) -> Void) async {
        do {
            switch try await knownHostsService.evaluate(host: session.host, port: session.port) {
            case .trusted:
                await MainActor.run {
                    self.startTransport(session: session, onConnected: onConnected)
                }
            case .prompt(let prompt):
                await MainActor.run {
                    self.pendingSession = session
                    self.pendingConnectedHandler = onConnected
                    self.hostKeyPrompt = prompt
                    if prompt.kind == .changed {
                        self.connectionState = .failed("检测到主机指纹变更，请先在弹窗中带外确认后再决定是否替换。")
                    } else if prompt.kind == .updated {
                        self.connectionState = .connecting
                        self.lastExitMessage = "检测到主机可用指纹集合已变化，请确认后更新本地 known_hosts。"
                    } else {
                        self.connectionState = .connecting
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.connectionState = .failed(error.localizedDescription)
            }
        }
    }

    private func startTransport(
        session: SSHSessionProfile,
        onConnected: @escaping (UUID) -> Void,
        passwordOverride: String? = nil,
        knownHostsPathOverride: String? = nil,
        strictHostKeyCheckingOverride: String? = nil
    ) {
        let password: String?
        if session.authMethod == .password {
            if let passwordOverride, !passwordOverride.isEmpty {
                password = passwordOverride
            } else if session.passwordStoredInKeychain {
                do {
                    password = try passwordStore.loadPassword(for: session.id)
                } catch {
                    passwordPrompt = SSHPasswordPrompt(
                        sessionName: session.name,
                        message: "读取系统 Keychain 中的 SSH 密码失败：\(error.localizedDescription)\n请改为输入本次连接密码。"
                    )
                    pendingSession = session
                    pendingConnectedHandler = onConnected
                    connectionState = .failed("无法访问系统 Keychain，请输入本次连接密码。")
                    return
                }
                if password?.isEmpty != false {
                    passwordPrompt = SSHPasswordPrompt(
                        sessionName: session.name,
                        message: "没有找到已保存的 SSH 密码，请输入本次连接密码。"
                    )
                    pendingSession = session
                    pendingConnectedHandler = onConnected
                    connectionState = .failed("未找到已保存密码，请输入本次连接密码。")
                    return
                }
            } else {
                passwordPrompt = SSHPasswordPrompt(
                    sessionName: session.name,
                    message: "该会话未保存 SSH 密码，请输入本次连接密码。"
                )
                pendingSession = session
                pendingConnectedHandler = onConnected
                connectionState = .failed("请先输入本次连接密码。")
                return
            }
        } else {
            password = nil
        }

        do {
            let knownHostsPath = if let knownHostsPathOverride {
                knownHostsPathOverride
            } else {
                try KnownHostsService.defaultKnownHostsFilePath()
            }
            transport.start(
                arguments: Self.sshArguments(
                    for: session,
                    userKnownHostsPath: knownHostsPath,
                    strictHostKeyChecking: strictHostKeyCheckingOverride ?? "no"
                ),
                password: password
            )
        } catch {
            connectionState = .failed("读取 known_hosts 路径失败：\(error.localizedDescription)")
            return
        }

        Task { @MainActor [weak self] in
            // 当前仍基于系统 ssh 进程，无法精确感知认证成功时刻；
            // 这里用“会话已启动且未退出”作为最小可用的连接成功近似条件。
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.startedSessionID == session.id else { return }
            if case .connecting = self.connectionState {
                self.connectionState = .connected
                onConnected(session.id)
            }
        }
    }

    private func configureAppearance(for terminalView: TerminalView) {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(
            calibratedRed: 0.88,
            green: 0.90,
            blue: 0.94,
            alpha: 1
        )
        terminalView.nativeBackgroundColor = NSColor(
            calibratedRed: 0.10,
            green: 0.11,
            blue: 0.14,
            alpha: 1
        )
        terminalView.caretColor = .systemGreen
        terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBlock)
        terminalView.autoresizingMask = [.width, .height]
    }

    private func handleUploadTrigger() {
        lastExitMessage = "已检测到 rz 上传请求，正在打开本地文件选择窗口。"
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "选择要通过 lrzsz 上传到远端的文件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let fileURL = panel.url {
            transferState = .transferring(.uploadToRemote)
            transport.startUpload(from: fileURL)
        } else {
            transport.cancelTransfer(sendCancel: true)
            transferState = .failed("已取消上传")
        }
    }

    private func handleDownloadTrigger() {
        lastExitMessage = "已检测到 sz 下载请求，正在打开保存目录选择窗口。"
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "选择接收 lrzsz 下载文件的目录"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let directoryURL = panel.url {
            transferState = .transferring(.downloadFromRemote)
            transport.startDownload(to: directoryURL)
        } else {
            transport.cancelTransfer(sendCancel: true)
            transferState = .failed("已取消下载")
        }
    }
}
