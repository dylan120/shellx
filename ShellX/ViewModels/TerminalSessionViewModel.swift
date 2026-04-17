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

private enum PasswordPromptPurpose {
    case sshConnection
    case sftpTransfer
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
    @Published var transientBannerMessage: String?
    @Published var transferState: ZModemTransferState = .idle
    @Published var hostKeyPrompt: KnownHostPrompt?
    @Published var passwordPrompt: SSHPasswordPrompt?
    @Published var zmodemSelectionRequest: ZModemSelectionRequest?
    @Published var sftpPathPrompt: SFTPPathPrompt?
    @Published var sftpLocalSelectionRequest: SFTPLocalSelectionRequest?
    @Published var terminalDebugSnapshot = ""
    @Published var hasTextSelection = false

    private weak var terminalView: TerminalView?
    private let transport = SSHPTYTransport()
    private let sftpService = SFTPTransferService()
    private let knownHostsService = KnownHostsService()
    private let passwordStore: SessionPasswordStore
    private var pendingTerminalOutput = Data()
    private let maxPendingTerminalOutputBytes = 1_048_576
    private var startedSessionID: UUID?
    private var activeSession: SSHSessionProfile?
    private var pendingSession: SSHSessionProfile?
    private var pendingConnectedHandler: ((UUID) -> Void)?
    private var pendingLocalShellPath: String?
    private var pendingLocalShellLaunchMode: LocalShellLaunchMode = .login
    private var pendingPasswordHandler: ((String) -> Void)?
    private var passwordPromptPurpose: PasswordPromptPurpose?
    private var hasAttemptedSSHPasswordAutofill = false
    private var transferBannerResetTask: Task<Void, Never>?
    private var connectionConfirmationTask: Task<Void, Never>?
    private var runtimeKind: TerminalRuntimeKind?
    private var pendingConnectedHandlerForActiveSession: ((UUID) -> Void)?
    private var isAwaitingSSHPasswordPrompt = false

    var bannerContent: (message: String, isError: Bool)? {
        if let transferMessage = transferState.bannerText {
            if case .failed = transferState {
                return (transferMessage, true)
            }
            return (transferMessage, false)
        }

        if let transientBannerMessage, !transientBannerMessage.isEmpty {
            return (transientBannerMessage, false)
        }

        if case .failed = connectionState, let lastExitMessage, !lastExitMessage.isEmpty {
            return (lastExitMessage, true)
        }

        return nil
    }

    var footerTransferSummary: String? {
        switch transferState {
        case .idle:
            return nil
        case .completed(let message), .failed(let message):
            return message
        default:
            return transferState.bannerText
        }
    }

    var footerTransferIsError: Bool {
        if case .failed = transferState {
            return true
        }
        return false
    }

    init(passwordStore: SessionPasswordStore = SessionPasswordStore()) {
        self.passwordStore = passwordStore
        super.init()
        transport.delegate = self
        sftpService.delegate = self
    }

    func attachTerminalView(_ terminalView: TerminalView) {
        if self.terminalView === terminalView {
            synchronizeTerminalSizeToTransport()
            flushPendingTerminalOutput(to: terminalView)
            return
        }
        self.terminalView = terminalView
        terminalView.terminalDelegate = self
        configureAppearance(for: terminalView)
        synchronizeTerminalSizeToTransport()
        flushPendingTerminalOutput(to: terminalView)

        if let pendingSession, let pendingConnectedHandler {
            self.pendingSession = nil
            self.pendingConnectedHandler = nil
            start(session: pendingSession, onConnected: pendingConnectedHandler)
        } else if let pendingLocalShellPath {
            let pendingLocalShellLaunchMode = self.pendingLocalShellLaunchMode
            self.pendingLocalShellPath = nil
            startLocalShell(shellPath: pendingLocalShellPath, launchMode: pendingLocalShellLaunchMode)
        }
    }

    private func feed(_ data: Data, to terminalView: TerminalView) {
        terminalView.feed(byteArray: Array(data)[...])
    }

    private func bufferPendingTerminalOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        pendingTerminalOutput.append(data)
        if pendingTerminalOutput.count > maxPendingTerminalOutputBytes {
            pendingTerminalOutput = Data(pendingTerminalOutput.suffix(maxPendingTerminalOutputBytes))
        }
    }

    private func flushPendingTerminalOutput(to terminalView: TerminalView) {
        guard !pendingTerminalOutput.isEmpty else { return }
        let data = pendingTerminalOutput
        pendingTerminalOutput.removeAll(keepingCapacity: true)
        feed(data, to: terminalView)
    }

    private func clearPendingTerminalOutput() {
        pendingTerminalOutput.removeAll(keepingCapacity: true)
    }

    func updateTextSelectionState(_ hasSelection: Bool) {
        hasTextSelection = hasSelection
    }

    func copySelectedText() {
        guard let terminalView,
              terminalView.selectedRange().length > 0 else {
            return
        }
        terminalView.copy(self)
    }

    func pasteClipboardText() {
        guard let terminalView else { return }
        terminalView.paste(self)
    }

    func copyConnectionHost(_ host: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmedHost, forType: .string)
        showTransientBanner("已复制当前连接地址：\(trimmedHost)")
    }

    func reconnect(session: SSHSessionProfile, onConnected: @escaping (UUID) -> Void) {
        terminate()
        start(session: session, onConnected: onConnected)
    }

    func startLocalShell(shellPath: String = "/bin/zsh", launchMode: LocalShellLaunchMode = .login) {
        clearPendingTerminalOutput()
        guard terminalView != nil else {
            pendingLocalShellPath = shellPath
            pendingLocalShellLaunchMode = launchMode
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
        transientBannerMessage = nil
        cancelTransferBannerReset()
        transferState = .idle
        hostKeyPrompt = nil
        passwordPrompt = nil
        passwordPromptPurpose = nil
        sftpPathPrompt = nil
        sftpLocalSelectionRequest = nil
        hasAttemptedSSHPasswordAutofill = false
        isAwaitingSSHPasswordPrompt = false
        pendingConnectedHandlerForActiveSession = nil
        cancelConnectionConfirmationTask()
        connectionState = .connecting
        pendingLocalShellPath = nil
        pendingLocalShellLaunchMode = launchMode

        transport.startLocalShell(
            shellPath: shellPath,
            arguments: launchMode.arguments,
            initialWindowSize: currentTerminalWindowSize()
        )

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
        clearPendingTerminalOutput()
        cancelTransferBannerReset()
        cancelConnectionConfirmationTask()
        if case .connected = connectionState {
            connectionState = .disconnected
        }
        transferState = .idle
        hostKeyPrompt = nil
        passwordPrompt = nil
        passwordPromptPurpose = nil
        sftpPathPrompt = nil
        sftpLocalSelectionRequest = nil
        activeSession = nil
        hasAttemptedSSHPasswordAutofill = false
        isAwaitingSSHPasswordPrompt = false
        pendingConnectedHandlerForActiveSession = nil
        pendingLocalShellPath = nil
        hasTextSelection = false
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
        guard let terminalView else {
            bufferPendingTerminalOutput(data)
            return
        }
        feed(data, to: terminalView)
    }

    func transportDidTerminate(exitCode: Int32?) {
        startedSessionID = nil
        activeSession = nil
        workingDirectory = nil
        cancelTransferBannerReset()
        cancelConnectionConfirmationTask()
        transferState = .idle
        hostKeyPrompt = nil
        isAwaitingSSHPasswordPrompt = false
        pendingConnectedHandlerForActiveSession = nil
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
                lastExitMessage = nil
                showTransientBanner("本机终端已关闭")
            } else {
                lastExitMessage = nil
                showTransientBanner("SSH 会话已正常关闭")
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

    func transportDidUpdateZModemProgress(_ progress: ZModemTransferProgress) {
        transferState = .transferring(progress)
    }

    func transportDidRequestPassword() {
        guard let session = activeSession, session.authMethod == .password else { return }
        isAwaitingSSHPasswordPrompt = true
        transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.requestedByTransport session=\(session.id.uuidString)")
        // 等远端真正提示 password 后，再尝试读取 Keychain 并自动回填。
        // 单次连接只尝试一次自动填充，避免错误密码或重复提示时再次触发系统授权。
        if let cachedPassword = passwordStore.cachedPassword(for: session.id), !cachedPassword.isEmpty {
            hasAttemptedSSHPasswordAutofill = true
            transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.begin source=runtimeCache")
            showTransientBanner("已从当前运行缓存中取到 SSH 密码，正在自动继续连接。", delaySeconds: 5)
            connectionState = .connecting
            isAwaitingSSHPasswordPrompt = false
            transport.providePassword(cachedPassword, source: .runtimeCache)
            scheduleConnectionConfirmationFallback(for: session.id)
            return
        }

        if session.passwordStoredInKeychain, !hasAttemptedSSHPasswordAutofill {
            hasAttemptedSSHPasswordAutofill = true
            transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.begin source=keychain")
            do {
                if let password = try passwordStore.loadPassword(for: session.id), !password.isEmpty {
                    transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.resolved source=keychain")
                    showTransientBanner("已从系统 Keychain 读取 SSH 密码，正在自动继续连接。", delaySeconds: 5)
                    connectionState = .connecting
                    isAwaitingSSHPasswordPrompt = false
                    transport.providePassword(password, source: .keychain)
                    scheduleConnectionConfirmationFallback(for: session.id)
                    return
                }
                transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.skipped.noPassword source=keychain")
            } catch {
                transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.failure source=keychain error=\(error.localizedDescription)")
                showTransientBanner("读取系统 Keychain 中的 SSH 密码失败：\(error.localizedDescription)。请先输入本次连接密码。", delaySeconds: 5)
            }
        } else if session.passwordStoredInKeychain {
            transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.skipped.alreadyAttempted source=keychain")
        }

        transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.manualPrompt.presented")
        passwordPrompt = SSHPasswordPrompt(
            sessionName: session.name,
            message: session.passwordStoredInKeychain
                ? "远端正在请求 SSH 密码。未能直接从系统 Keychain 读取到可用密码，请输入一次本次连接密码；如果该会话开启了“保存到系统 Keychain”，ShellX 会在本次输入后重新写入。"
                : "远端正在请求 SSH 密码。请输入一次本次连接密码。"
        )
        passwordPromptPurpose = .sshConnection
    }

    func transportDidFail(_ message: String) {
        cancelConnectionConfirmationTask()
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
                    self.showTransientBanner("主机指纹已写入 ShellX 的 known_hosts，正在继续连接。")
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
        pendingConnectedHandlerForActiveSession = nil
        cancelConnectionConfirmationTask()
        connectionState = .failed("已取消主机指纹确认")
    }

    func submitPasswordAndContinue(_ password: String) {
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else { return }

        if let pendingPasswordHandler {
            passwordPrompt = nil
            self.pendingPasswordHandler = nil
            passwordPromptPurpose = nil
            pendingPasswordHandler(trimmedPassword)
            return
        }

        if passwordPromptPurpose == .sshConnection, let activeSession, activeSession.authMethod == .password {
            passwordStore.cachePassword(trimmedPassword, for: activeSession.id)
            if activeSession.passwordStoredInKeychain {
                do {
                    try passwordStore.savePassword(trimmedPassword, for: activeSession.id)
                } catch {
                    showTransientBanner("保存到系统 Keychain 失败：\(error.localizedDescription)。本次连接仍会继续，并在当前运行期间复用已输入密码。", delaySeconds: 5)
                }
            }

            passwordPrompt = nil
            passwordPromptPurpose = nil
            isAwaitingSSHPasswordPrompt = false
            showTransientBanner("正在使用本次输入的密码继续连接。")
            connectionState = .connecting
            transport.recordSSHAuthDebugEvent("ssh.passwordPrompt.manualPrompt.submitted")
            transport.providePassword(trimmedPassword, source: .manual)
            scheduleConnectionConfirmationFallback(for: activeSession.id)
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
                    showTransientBanner("保存到系统 Keychain 失败：\(error.localizedDescription)。本次连接仍会继续，并在当前运行期间复用已输入密码。", delaySeconds: 5)
                }
            }
        }

        passwordPrompt = nil
        passwordPromptPurpose = nil
        showTransientBanner("正在使用本次输入的密码继续连接。")
        connectionState = .connecting
        self.pendingSession = nil
        self.pendingConnectedHandler = nil
        startTransport(session: pendingSession, onConnected: pendingConnectedHandler, passwordOverride: trimmedPassword)
    }

    func cancelPasswordPrompt() {
        if pendingPasswordHandler != nil {
            passwordPrompt = nil
            pendingPasswordHandler = nil
            passwordPromptPurpose = nil
            showTransientBanner("已取消 SFTP 密码输入。")
            return
        }
        if passwordPromptPurpose == .sshConnection {
            passwordPrompt = nil
            passwordPromptPurpose = nil
            isAwaitingSSHPasswordPrompt = false
            pendingConnectedHandlerForActiveSession = nil
            cancelConnectionConfirmationTask()
            transport.terminate()
            connectionState = .failed("已取消密码输入")
            return
        }
        passwordPrompt = nil
        pendingPasswordHandler = nil
        passwordPromptPurpose = nil
        pendingSession = nil
        pendingConnectedHandler = nil
        pendingConnectedHandlerForActiveSession = nil
        cancelConnectionConfirmationTask()
        connectionState = .failed("已取消密码输入")
    }

    func handleUploadSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let fileURLs):
            guard !fileURLs.isEmpty else {
                transport.cancelTransfer(sendCancel: true)
                transferState = .failed("未选择要上传的文件")
                lastExitMessage = "未选择要上传的文件"
                scheduleTransferBannerReset(message: "未选择要上传的文件")
                zmodemSelectionRequest = nil
                return
            }
            cancelTransferBannerReset()
            let progress = ZModemTransferProgress(
                direction: .uploadToRemote,
                completedFiles: 0,
                totalFiles: fileURLs.count
            )
            transferState = .transferring(progress)
            transport.startUpload(from: fileURLs)
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
            transferState = .transferring(ZModemTransferProgress(direction: .downloadFromRemote))
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
            showTransientBanner("只有已连接的会话才能发起 SFTP 传输。")
            return
        }
        cancelTransferBannerReset()
        showTransientBanner("正在选择要通过 SFTP 上传的本地文件或文件夹。")
        sftpLocalSelectionRequest = .uploadSource
    }

    func requestSFTPDownloadFile() {
        guard case .connected = connectionState else {
            showTransientBanner("只有已连接的会话才能发起 SFTP 传输。")
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
            showTransientBanner("只有已连接的会话才能发起 SFTP 传输。")
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
            showTransientBanner("已取消 SFTP 路径选择。")
        }
    }

    func handleSFTPPathPromptConfirm(_ prompt: SFTPPathPrompt, path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        sftpPathPrompt = nil

        switch prompt.kind {
        case .upload(let localURL):
            beginSFTPUpload(localURL: localURL, remoteDirectory: trimmedPath)
        case .downloadFile:
            showTransientBanner("正在选择 SFTP 下载目标目录。")
            sftpLocalSelectionRequest = .downloadDestination(remotePath: trimmedPath, recursive: false)
        case .downloadDirectory:
            showTransientBanner("正在选择 SFTP 下载目标目录。")
            sftpLocalSelectionRequest = .downloadDestination(remotePath: trimmedPath, recursive: true)
        }
    }

    func handleSFTPPathPromptCancel() {
        sftpPathPrompt = nil
        showTransientBanner("已取消 SFTP 传输。")
    }

    func cancelActiveTransferFromKeyboard() -> Bool {
        switch transferState {
        case .preparing(.uploadToRemote), .preparing(.downloadFromRemote), .transferring(_):
            transport.cancelTransfer(sendCancel: true)
            markTransferCancelled("已取消 lrzsz 传输")
            return true
        case .sftpTransferring(_):
            sftpService.terminate()
            markTransferCancelled("已取消 SFTP 传输")
            return true
        case .idle, .completed(_), .failed(_):
            return false
        }
    }

    private func start(session: SSHSessionProfile, onConnected: @escaping (UUID) -> Void) {
        clearPendingTerminalOutput()
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
        transientBannerMessage = nil
        cancelTransferBannerReset()
        transferState = .idle
        connectionState = .connecting
        pendingSession = nil
        pendingConnectedHandler = nil
        hostKeyPrompt = nil
        passwordPrompt = nil
        passwordPromptPurpose = nil
        hasAttemptedSSHPasswordAutofill = false
        isAwaitingSSHPasswordPrompt = false
        pendingConnectedHandlerForActiveSession = onConnected
        cancelConnectionConfirmationTask()

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
                        self.showTransientBanner("检测到主机可用指纹集合已变化，请确认后更新本地 known_hosts。", delaySeconds: 5)
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
        let password = session.authMethod == .password ? passwordOverride : nil

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
                password: password,
                initialWindowSize: currentTerminalWindowSize()
            )
        } catch {
            connectionState = .failed("读取 known_hosts 路径失败：\(error.localizedDescription)")
            return
        }

        scheduleConnectionConfirmationFallback(for: session.id)
    }

    private func configureAppearance(for terminalView: TerminalView) {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(
            calibratedRed: 0.90,
            green: 0.93,
            blue: 0.97,
            alpha: 1
        )
        terminalView.nativeBackgroundColor = NSColor(
            calibratedRed: 0.03,
            green: 0.04,
            blue: 0.05,
            alpha: 1
        )
        // 切到更鲜艳的 xterm 256 色派生策略，避免 16 色之外的 ANSI/256 色高亮继续发灰。
        terminalView.getTerminal().options.ansi256PaletteStrategy = .xterm
        // 为 ANSI 16 色提供更高对比的基色，避免 ls、日志等级和告警色在深色背景上发灰发白。
        terminalView.installColors(Self.highContrastTerminalPalette)
        terminalView.caretColor = .systemGreen
        terminalView.layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        terminalView.getTerminal().setCursorStyle(.steadyBlock)
        terminalView.autoresizingMask = [.width, .height]
    }

    private func currentTerminalWindowSize() -> (cols: Int, rows: Int)? {
        guard let terminalView else { return nil }
        let terminal = terminalView.getTerminal()
        guard terminal.cols > 0, terminal.rows > 0 else { return nil }
        return (cols: terminal.cols, rows: terminal.rows)
    }

    private func synchronizeTerminalSizeToTransport() {
        guard let size = currentTerminalWindowSize() else { return }
        transport.resize(cols: size.cols, rows: size.rows)
    }

    private func markTransferCancelled(_ message: String) {
        cancelTransferBannerReset()
        transferState = .failed(message)
        lastExitMessage = message
        scheduleTransferBannerReset(message: message)
    }

    private static let highContrastTerminalPalette: [Color] = [
        color8(0x24, 0x2B, 0x35), // black
        color8(0xFF, 0x86, 0x7F), // red
        color8(0x7E, 0xFF, 0xA3), // green
        color8(0xFF, 0xE1, 0x66), // yellow
        color8(0x97, 0xD5, 0xFF), // blue
        color8(0xF2, 0xA7, 0xFF), // magenta
        color8(0x6E, 0xF4, 0xF4), // cyan
        color8(0xEE, 0xF3, 0xFA), // white
        color8(0x7C, 0x88, 0x9B), // bright black
        color8(0xFF, 0xB2, 0xAC), // bright red
        color8(0xB3, 0xFF, 0xCA), // bright green
        color8(0xFF, 0xF0, 0x8A), // bright yellow
        color8(0xC0, 0xE3, 0xFF), // bright blue
        color8(0xFB, 0xCF, 0xFF), // bright magenta
        color8(0xAE, 0xFF, 0xFF), // bright cyan
        color8(0xFF, 0xFF, 0xFF)  // bright white
    ]

    private static func color8(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> Color {
        // 当前 SwiftTerm 版本只暴露 16 位通道初始化器，这里把常见 8 位 RGB 放大到 16 位。
        Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    private func handleUploadTrigger() {
        cancelTransferBannerReset()
        transientBannerMessage = nil
        zmodemSelectionRequest = .upload
    }

    private func handleDownloadTrigger() {
        cancelTransferBannerReset()
        transientBannerMessage = nil
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
            cancelTransferBannerReset()
            transferState = .sftpTransferring(SFTPTransferProgress(direction: operation.transferDirection))
            sftpService.start(
                session: session,
                operation: operation,
                knownHostsPath: knownHostsPath,
                password: passwordOverride
            )
        } catch {
            showTransientBanner("启动 SFTP 失败：\(error.localizedDescription)", delaySeconds: 5)
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
                showTransientBanner("读取系统 Keychain 中的密码失败：\(error.localizedDescription)。请先输入本次传输密码。", delaySeconds: 5)
            }
        }

        passwordPrompt = SSHPasswordPrompt(
            sessionName: session.name,
            message: "当前 SFTP 传输需要 SSH 密码。请输入一次本次传输密码；如果该会话开启了“保存到系统 Keychain”，ShellX 会在本次输入后重新写入。"
        )
        passwordPromptPurpose = .sftpTransfer
        pendingPasswordHandler = { [weak self] password in
            guard let self else { return }
            self.passwordStore.cachePassword(password, for: session.id)
            if session.passwordStoredInKeychain {
                do {
                    try self.passwordStore.savePassword(password, for: session.id)
                } catch {
                    self.showTransientBanner("保存到系统 Keychain 失败：\(error.localizedDescription)。本次 SFTP 传输仍会继续。", delaySeconds: 5)
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
            if self.transientBannerMessage == message {
                self.transientBannerMessage = nil
            }
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

    private func scheduleConnectionConfirmationFallback(for sessionID: UUID) {
        cancelConnectionConfirmationTask()
        connectionConfirmationTask = Task { @MainActor [weak self] in
            // SSH 认证阶段可能先出现 banner、MFA 或密码提示，不能再像之前那样很快直接标记为已连接。
            // 这里仅保留一个更长的兜底超时，优先等待真实终端信号（标题/CWD 更新）来确认连接成功。
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            guard self.startedSessionID == sessionID else { return }
            guard self.hostKeyPrompt == nil, !self.isAwaitingSSHPasswordPrompt else { return }
            self.markSSHSessionConnectedIfNeeded(sessionID: sessionID)
        }
    }

    private func cancelConnectionConfirmationTask() {
        connectionConfirmationTask?.cancel()
        connectionConfirmationTask = nil
    }

    private func markSSHSessionConnectedIfNeeded(sessionID: UUID? = nil) {
        guard case .connecting = connectionState else { return }
        guard let activeSession else { return }
        guard runtimeKind == .ssh(activeSession) else { return }
        if let sessionID, activeSession.id != sessionID {
            return
        }

        connectionState = .connected
        isAwaitingSSHPasswordPrompt = false
        cancelConnectionConfirmationTask()

        if let pendingConnectedHandlerForActiveSession {
            self.pendingConnectedHandlerForActiveSession = nil
            pendingConnectedHandlerForActiveSession(activeSession.id)
        }
    }

    // 普通提示与错误分流：临时提示走这里并自动消失，真正错误仍保留在 lastExitMessage。
    private func showTransientBanner(_ message: String, delaySeconds: Double = 3) {
        transientBannerMessage = message
        scheduleTransferBannerReset(message: message, delaySeconds: delaySeconds)
    }

    func sftpTransferDidStart(message: String) {
        cancelTransferBannerReset()
        if case .sftpTransferring = transferState {
            transientBannerMessage = nil
        } else {
            transferState = .idle
            showTransientBanner(message)
        }
    }

    func sftpTransferDidUpdate(progress: SFTPTransferProgress) {
        transferState = .sftpTransferring(progress)
    }

    func sftpTransferDidComplete(message: String) {
        transferState = .completed(message)
        showTransientBanner(message)
    }

    func sftpTransferDidFail(message: String) {
        transferState = .failed(message)
        showTransientBanner(message, delaySeconds: 5)
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
            let nextTitle = trimmed.isEmpty ? (self.runtimeKind?.defaultTitle ?? "终端") : title
            guard self.terminalTitle != nextTitle else { return }
            self.terminalTitle = nextTitle
            self.markSSHSessionConnectedIfNeeded()
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.workingDirectory != directory else { return }
            self.workingDirectory = directory
            self.markSSHSessionConnectedIfNeeded()
        }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let buffer = Data(data)
        Task { @MainActor [weak self] in
            let normalizedBuffer = TerminalKeyInputNormalizer.normalizedTerminalInput(buffer)
            guard !normalizedBuffer.isEmpty else { return }
            if normalizedBuffer == Data([0x03]),
               self?.cancelActiveTransferFromKeyboard() == true {
                return
            }
            self?.transport.send(normalizedBuffer)
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
