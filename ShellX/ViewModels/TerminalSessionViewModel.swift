import AppKit
import Foundation
@preconcurrency import SwiftTerm

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

struct SFTPPathPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        case upload(localURL: URL)
        case downloadFile
        case downloadDirectory
    }

    let id = UUID()
    let sessionName: String
    let title: String
    let message: String
    let defaultPath: String
    let kind: Kind
}

enum ZModemSelectionRequest: Identifiable, Equatable {
    case upload
    case download

    var id: String {
        switch self {
        case .upload:
            return "upload"
        case .download:
            return "download"
        }
    }
}

enum SFTPLocalSelectionRequest: Identifiable, Equatable {
    case uploadSource
    case downloadDestination(remotePath: String, recursive: Bool)

    var id: String {
        switch self {
        case .uploadSource:
            return "uploadSource"
        case .downloadDestination(let remotePath, let recursive):
            return "downloadDestination-\(remotePath)-\(recursive)"
        }
    }
}

private enum TerminalRuntimeKind: Equatable {
    case ssh(SSHSessionProfile)
    case local(shellPath: String)

    var defaultTitle: String {
        switch self {
        case .ssh:
            return "SSH 控制台"
        case .local:
            return "本机终端"
        }
    }
}

@MainActor
final class TerminalSessionViewModel: NSObject, ObservableObject, SSHPTYTransportDelegate, SFTPTransferServiceDelegate {
    @Published var connectionState: TerminalConnectionState = .idle
    @Published var terminalTitle = "SSH 控制台"
    @Published var workingDirectory: String?
    @Published var lastExitMessage: String?
    @Published var transferState: ZModemTransferState = .idle
    @Published var hostKeyPrompt: KnownHostPrompt?
    @Published var passwordPrompt: SSHPasswordPrompt?
    @Published var zmodemSelectionRequest: ZModemSelectionRequest?
    @Published var sftpPathPrompt: SFTPPathPrompt?
    @Published var sftpLocalSelectionRequest: SFTPLocalSelectionRequest?
    @Published var terminalDebugSnapshot = ""

    private weak var terminalView: TerminalView?
    private let transport = SSHPTYTransport()
    private let sftpService = SFTPTransferService()
    private let knownHostsService = KnownHostsService()
    private let passwordStore: SessionPasswordStore
    private var startedSessionID: UUID?
    private var activeSession: SSHSessionProfile?
    private var pendingSession: SSHSessionProfile?
    private var pendingConnectedHandler: ((UUID) -> Void)?
    private var pendingLocalShellPath: String?
    private var pendingPasswordHandler: ((String) -> Void)?
    private var transferBannerResetTask: Task<Void, Never>?
    private var runtimeKind: TerminalRuntimeKind?

    init(passwordStore: SessionPasswordStore = SessionPasswordStore()) {
        self.passwordStore = passwordStore
        super.init()
        transport.delegate = self
        sftpService.delegate = self
    }

    func attachTerminalView(_ terminalView: TerminalView) {
        if self.terminalView === terminalView {
            return
        }
        self.terminalView = terminalView
        terminalView.terminalDelegate = self
        configureAppearance(for: terminalView)

        if let pendingSession, let pendingConnectedHandler {
            self.pendingSession = nil
            self.pendingConnectedHandler = nil
            start(session: pendingSession, onConnected: pendingConnectedHandler)
        } else if let pendingLocalShellPath {
            self.pendingLocalShellPath = nil
            startLocalShell(shellPath: pendingLocalShellPath)
        }
    }

    func reconnect(session: SSHSessionProfile, onConnected: @escaping (UUID) -> Void) {
        terminate()
        start(session: session, onConnected: onConnected)
    }

    func startLocalShell(shellPath: String = "/bin/zsh") {
        guard terminalView != nil else {
            pendingLocalShellPath = shellPath
            runtimeKind = .local(shellPath: shellPath)
            terminalTitle = TerminalRuntimeKind.local(shellPath: shellPath).defaultTitle
            connectionState = .connecting
            return
        }

        startedSessionID = nil
        activeSession = nil
        runtimeKind = .local(shellPath: shellPath)
        terminalTitle = TerminalRuntimeKind.local(shellPath: shellPath).defaultTitle
        workingDirectory = nil
        lastExitMessage = nil
        cancelTransferBannerReset()
        transferState = .idle
        hostKeyPrompt = nil
        sftpPathPrompt = nil
        sftpLocalSelectionRequest = nil
        connectionState = .connecting
        pendingLocalShellPath = nil

        transport.startLocalShell(shellPath: shellPath)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            guard case .connecting = self.connectionState else { return }
            guard self.runtimeKind == .local(shellPath: shellPath) else { return }
            self.connectionState = .connected
        }
    }

    func terminate() {
        transport.terminate()
        sftpService.terminate()
        cancelTransferBannerReset()
        if case .connected = connectionState {
            connectionState = .disconnected
        }
        transferState = .idle
        hostKeyPrompt = nil
        sftpPathPrompt = nil
        sftpLocalSelectionRequest = nil
        activeSession = nil
        pendingLocalShellPath = nil
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
                args.append(contentsOf: ["-o", "IdentitiesOnly=yes"])
            }
            if session.useKeychainForPrivateKey {
                args.append(contentsOf: ["-o", "UseKeychain=yes"])
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

    func transportDidReceive(_ data: Data) {
        terminalView?.feed(byteArray: Array(data)[...])
    }

    func transportDidTerminate(exitCode: Int32?) {
        startedSessionID = nil
        activeSession = nil
        workingDirectory = nil
        cancelTransferBannerReset()
        transferState = .idle
        hostKeyPrompt = nil
        let runtimeKind = self.runtimeKind

        guard let exitCode else {
            let message = "\(runtimeKind?.defaultTitle ?? "终端")异常结束"
            connectionState = .failed(message)
            lastExitMessage = message
            return
        }

        if exitCode == 0 {
            connectionState = .disconnected
            if case .local = runtimeKind {
                lastExitMessage = "本机终端已关闭"
            } else {
                lastExitMessage = "SSH 会话已正常关闭"
            }
        } else {
            let message = "\(runtimeKind?.defaultTitle ?? "终端")退出，退出码 \(exitCode)"
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
            scheduleTransferBannerReset(message: message)
        } else {
            transferState = .failed(message)
            if message.contains("传输") || message.contains("上传") || message.contains("下载") || message.contains("已取消") {
                scheduleTransferBannerReset(message: message)
            }
        }
        lastExitMessage = message
    }

    func transportDidUpdateDebugSnapshot(_ snapshot: String) {
        terminalDebugSnapshot = snapshot
    }

    func clearTerminalDebugSnapshot() {
        terminalDebugSnapshot = ""
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
        guard !trimmedPassword.isEmpty else { return }

        if let pendingPasswordHandler {
            passwordPrompt = nil
            self.pendingPasswordHandler = nil
            pendingPasswordHandler(trimmedPassword)
            return
        }

        guard let pendingSession,
              let pendingConnectedHandler else { return }

        if pendingSession.authMethod == .password {
            // 账号密码模式优先复用本次输入的密码，避免同一进程内再次触发系统 Keychain 授权。
            passwordStore.cachePassword(trimmedPassword, for: pendingSession.id)
            if pendingSession.passwordStoredInKeychain {
                do {
                    try passwordStore.savePassword(trimmedPassword, for: pendingSession.id)
                } catch {
                    lastExitMessage = "保存到系统 Keychain 失败：\(error.localizedDescription)。本次连接仍会继续，并在当前运行期间复用已输入密码。"
                }
            }
        }

        passwordPrompt = nil
        lastExitMessage = "正在使用本次输入的密码继续连接。"
        connectionState = .connecting
        self.pendingSession = nil
        self.pendingConnectedHandler = nil
        startTransport(session: pendingSession, onConnected: pendingConnectedHandler, passwordOverride: trimmedPassword)
    }

    func cancelPasswordPrompt() {
        if pendingPasswordHandler != nil {
            passwordPrompt = nil
            pendingPasswordHandler = nil
            lastExitMessage = "已取消 SFTP 密码输入。"
            scheduleTransferBannerReset(message: "已取消 SFTP 密码输入。")
            return
        }
        passwordPrompt = nil
        pendingPasswordHandler = nil
        pendingSession = nil
        pendingConnectedHandler = nil
        connectionState = .failed("已取消密码输入")
    }

    func handleUploadSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let fileURL):
            cancelTransferBannerReset()
            transferState = .transferring(.uploadToRemote)
            lastExitMessage = "已选择文件，正在上传到远端。"
            transport.startUpload(from: fileURL)
        case .failure:
            transport.cancelTransfer(sendCancel: true)
            transferState = .failed("已取消上传")
            lastExitMessage = "已取消上传"
            scheduleTransferBannerReset(message: "已取消上传")
        }
        zmodemSelectionRequest = nil
    }

    func handleDownloadSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let directoryURL):
            cancelTransferBannerReset()
            transferState = .transferring(.downloadFromRemote)
            lastExitMessage = "已选择接收目录，正在从远端下载。"
            transport.startDownload(to: directoryURL)
        case .failure:
            transport.cancelTransfer(sendCancel: true)
            transferState = .failed("已取消下载")
            lastExitMessage = "已取消下载"
            scheduleTransferBannerReset(message: "已取消下载")
        }
        zmodemSelectionRequest = nil
    }

    func requestSFTPUpload() {
        guard case .connected = connectionState else {
            lastExitMessage = "只有已连接的会话才能发起 SFTP 传输。"
            return
        }
        cancelTransferBannerReset()
        lastExitMessage = "正在选择要通过 SFTP 上传的本地文件或文件夹。"
        sftpLocalSelectionRequest = .uploadSource
    }

    func requestSFTPDownloadFile() {
        guard case .connected = connectionState else {
            lastExitMessage = "只有已连接的会话才能发起 SFTP 传输。"
            return
        }
        sftpPathPrompt = SFTPPathPrompt(
            sessionName: terminalTitle,
            title: "SFTP 下载文件",
            message: "请输入要从远端下载的文件路径，然后选择本地保存目录。",
            defaultPath: workingDirectory ?? ".",
            kind: .downloadFile
        )
    }

    func requestSFTPDownloadDirectory() {
        guard case .connected = connectionState else {
            lastExitMessage = "只有已连接的会话才能发起 SFTP 传输。"
            return
        }
        sftpPathPrompt = SFTPPathPrompt(
            sessionName: terminalTitle,
            title: "SFTP 下载文件夹",
            message: "请输入要从远端递归下载的文件夹路径，然后选择本地保存目录。",
            defaultPath: workingDirectory ?? ".",
            kind: .downloadDirectory
        )
    }

    func handleSFTPLocalSelection(_ result: Result<URL, Error>) {
        let request = sftpLocalSelectionRequest
        sftpLocalSelectionRequest = nil

        switch result {
        case .success(let url):
            guard let request else { return }
            switch request {
            case .uploadSource:
                sftpPathPrompt = SFTPPathPrompt(
                    sessionName: terminalTitle,
                    title: "SFTP 上传目标路径",
                    message: "请输入远端保存目录。若留空，将使用当前远端目录。",
                    defaultPath: workingDirectory ?? ".",
                    kind: .upload(localURL: url)
                )
            case .downloadDestination(let remotePath, let recursive):
                if recursive {
                    beginSFTPDownload(remotePath: remotePath, localDirectory: url, recursive: true)
                } else {
                    beginSFTPDownload(remotePath: remotePath, localDirectory: url, recursive: false)
                }
            }
        case .failure:
            lastExitMessage = "已取消 SFTP 路径选择。"
            scheduleTransferBannerReset(message: "已取消 SFTP 路径选择。")
        }
    }

    func handleSFTPPathPromptConfirm(_ prompt: SFTPPathPrompt, path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        sftpPathPrompt = nil

        switch prompt.kind {
        case .upload(let localURL):
            beginSFTPUpload(localURL: localURL, remoteDirectory: trimmedPath)
        case .downloadFile:
            lastExitMessage = "正在选择 SFTP 下载目标目录。"
            sftpLocalSelectionRequest = .downloadDestination(remotePath: trimmedPath, recursive: false)
        case .downloadDirectory:
            lastExitMessage = "正在选择 SFTP 下载目标目录。"
            sftpLocalSelectionRequest = .downloadDestination(remotePath: trimmedPath, recursive: true)
        }
    }

    func handleSFTPPathPromptCancel() {
        sftpPathPrompt = nil
        lastExitMessage = "已取消 SFTP 传输。"
        scheduleTransferBannerReset(message: "已取消 SFTP 传输。")
    }

    private func start(session: SSHSessionProfile, onConnected: @escaping (UUID) -> Void) {
        guard terminalView != nil else {
            pendingSession = session
            pendingConnectedHandler = onConnected
            connectionState = .connecting
            runtimeKind = .ssh(session)
            return
        }

        startedSessionID = session.id
        activeSession = session
        runtimeKind = .ssh(session)
        terminalTitle = session.name
        workingDirectory = nil
        lastExitMessage = nil
        cancelTransferBannerReset()
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
                        message: "读取系统 Keychain 中的密码失败：\(error.localizedDescription)\n\n请输入本次连接密码；如果该会话开启了“保存到系统 Keychain”，ShellX 会在本次输入后重新写入。"
                    )
                    pendingSession = session
                    pendingConnectedHandler = onConnected
                    connectionState = .failed("无法读取系统 Keychain，请先输入本次连接密码。")
                    return
                }

                if password?.isEmpty != false {
                    passwordPrompt = SSHPasswordPrompt(
                        sessionName: session.name,
                        message: "当前会话尚未保存密码。请输入一次本次连接密码；如果该会话开启了“保存到系统 Keychain”，ShellX 会在本次输入后写入，后续重启应用也可直接连接。"
                    )
                    pendingSession = session
                    pendingConnectedHandler = onConnected
                    connectionState = .failed("请先输入本次连接密码。")
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
        cancelTransferBannerReset()
        lastExitMessage = "已检测到 rz 上传请求，正在打开本地文件选择窗口。"
        zmodemSelectionRequest = .upload
    }

    private func handleDownloadTrigger() {
        cancelTransferBannerReset()
        lastExitMessage = "已检测到 sz 下载请求，正在打开保存目录选择窗口。"
        zmodemSelectionRequest = .download
    }

    private func beginSFTPUpload(localURL: URL, remoteDirectory: String) {
        guard let session = currentSession else { return }
        resolvePasswordIfNeeded(for: session) { [weak self] password in
            guard let self else { return }
            self.startSFTPOperation(
                .upload(localURL: localURL, remoteDirectory: remoteDirectory),
                session: session,
                passwordOverride: password
            )
        }
    }

    private func beginSFTPDownload(remotePath: String, localDirectory: URL, recursive: Bool) {
        guard let session = currentSession else { return }
        let operation: SFTPOperation = recursive
            ? .downloadDirectory(remotePath: remotePath, localDirectory: localDirectory)
            : .downloadFile(remotePath: remotePath, localDirectory: localDirectory)
        resolvePasswordIfNeeded(for: session) { [weak self] password in
            guard let self else { return }
            self.startSFTPOperation(operation, session: session, passwordOverride: password)
        }
    }

    private func startSFTPOperation(
        _ operation: SFTPOperation,
        session: SSHSessionProfile,
        passwordOverride: String?
    ) {
        do {
            let knownHostsPath = try KnownHostsService.defaultKnownHostsFilePath()
            sftpService.start(
                session: session,
                operation: operation,
                knownHostsPath: knownHostsPath,
                password: passwordOverride
            )
        } catch {
            lastExitMessage = "启动 SFTP 失败：\(error.localizedDescription)"
            scheduleTransferBannerReset(message: "启动 SFTP 失败：\(error.localizedDescription)")
        }
    }

    private func resolvePasswordIfNeeded(
        for session: SSHSessionProfile,
        onResolved: @escaping (String?) -> Void
    ) {
        guard session.authMethod == .password else {
            onResolved(nil)
            return
        }

        if let cachedPassword = passwordStore.cachedPassword(for: session.id), !cachedPassword.isEmpty {
            onResolved(cachedPassword)
            return
        }

        if session.passwordStoredInKeychain {
            do {
                if let password = try passwordStore.loadPassword(for: session.id), !password.isEmpty {
                    onResolved(password)
                    return
                }
            } catch {
                lastExitMessage = "读取系统 Keychain 中的密码失败：\(error.localizedDescription)。请先输入本次传输密码。"
            }
        }

        passwordPrompt = SSHPasswordPrompt(
            sessionName: session.name,
            message: "当前 SFTP 传输需要 SSH 密码。请输入一次本次传输密码；如果该会话开启了“保存到系统 Keychain”，ShellX 会在本次输入后重新写入。"
        )
        pendingPasswordHandler = { [weak self] password in
            guard let self else { return }
            self.passwordStore.cachePassword(password, for: session.id)
            if session.passwordStoredInKeychain {
                do {
                    try self.passwordStore.savePassword(password, for: session.id)
                } catch {
                    self.lastExitMessage = "保存到系统 Keychain 失败：\(error.localizedDescription)。本次 SFTP 传输仍会继续。"
                }
            }
            onResolved(password)
        }
    }

    private var currentSession: SSHSessionProfile? {
        activeSession
    }

    private func scheduleTransferBannerReset(message: String, delaySeconds: Double = 3) {
        cancelTransferBannerReset()
        transferBannerResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self else { return }
            if self.lastExitMessage == message {
                self.lastExitMessage = nil
            }
            if case .completed(let currentMessage) = self.transferState, currentMessage == message {
                self.transferState = .idle
            } else if case .failed(let currentMessage) = self.transferState, currentMessage == message {
                self.transferState = .idle
            }
            self.transferBannerResetTask = nil
        }
    }

    private func cancelTransferBannerReset() {
        transferBannerResetTask?.cancel()
        transferBannerResetTask = nil
    }

    func sftpTransferDidStart(message: String) {
        cancelTransferBannerReset()
        lastExitMessage = message
    }

    func sftpTransferDidComplete(message: String) {
        lastExitMessage = message
        scheduleTransferBannerReset(message: message)
    }

    func sftpTransferDidFail(message: String) {
        lastExitMessage = message
        scheduleTransferBannerReset(message: message, delaySeconds: 5)
    }
}

extension TerminalSessionViewModel: TerminalViewDelegate {
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            self?.transport.resize(cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.terminalTitle = trimmed.isEmpty ? (self.runtimeKind?.defaultTitle ?? "终端") : title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            self?.workingDirectory = directory
        }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let buffer = Data(data)
        Task { @MainActor [weak self] in
            self?.transport.send(buffer)
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        guard let url = URL(string: link) else { return }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func bell(source: TerminalView) {
        Task { @MainActor in
            NSSound.beep()
        }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        Task { @MainActor in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
    }
}
