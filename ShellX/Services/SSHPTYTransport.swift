import Darwin
import Foundation

@MainActor
protocol SSHPTYTransportDelegate: AnyObject {
    func transportDidReceive(_ data: Data)
    func transportDidTerminate(exitCode: Int32?)
    func transportDidDetectZModem(_ trigger: ZModemTrigger)
    func transportDidUpdateZModemProgress(_ progress: ZModemTransferProgress)
    func transportDidRequestPassword()
    func transportDidFail(_ message: String)
    func transportDidUpdateDebugSnapshot(_ snapshot: String)
}

enum SSHPasswordSource: String {
    case runtimeCache
    case keychain
    case manual
}

final class SSHPTYTransport {
    weak var delegate: SSHPTYTransportDelegate?

    private let ioQueue = DispatchQueue(label: "com.shellx.transport.io", qos: .userInitiated)
    private var masterFD: Int32 = -1
    private var sshPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private var helperProcess: Process?
    private var helperStdIn: Pipe?
    private var helperStdOut: Pipe?
    private var helperStdErr: Pipe?
    private var helperOutputHandler: DispatchSourceRead?
    private var helperErrorHandler: DispatchSourceRead?
    private var zmodemDetector = ZModemTriggerDetector()
    private var pendingTrigger: ZModemTrigger?
    private var pendingData = Data()
    private var transferDirection: ZModemTransferDirection?
    private var progressParser: ZModemProgressParser?
    private var didSeeDownloadCompletionFrame = false
    private var isCancellingTransfer = false
    private var pendingPassword: String?
    private var pendingPasswordSource: SSHPasswordSource?
    private var authTranscript = ""
    private var didSendPassword = false
    private var didRequestPasswordResolution = false
    private var didLogRepeatedPasswordPrompt = false
    private var lastWindowSize: (cols: Int, rows: Int)?
    private var debugTranscript = ""
    private let maxDebugTranscriptLength = 65536
    private let maxDebugBytesPerRead = 4096
    private var currentUserCommandBuffer = ""
    private var lastSubmittedUserCommand: String?
    private var activeProcessToken: UInt64 = 0
    private var lastDebugSnapshotPublishTime: DispatchTime?
    private let minDebugSnapshotPublishIntervalNanoseconds: UInt64 = 250_000_000

    // Swift 无法稳定直接导入 wait(2) 相关 C 宏，这里按 Darwin 的状态位规则自行解析。
    private static func waitStatus(_ status: Int32) -> Int32 {
        status & 0o177
    }

    private static func didExit(_ status: Int32) -> Bool {
        waitStatus(status) == 0
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        (status >> 8) & 0xFF
    }

    private static func didTerminateBySignal(_ status: Int32) -> Bool {
        let signal = waitStatus(status)
        return signal != 0 && signal != 0o177
    }

    private static func terminationSignal(_ status: Int32) -> Int32 {
        waitStatus(status)
    }

    deinit {
        terminate()
    }

    func start(
        arguments: [String],
        password: String? = nil,
        initialWindowSize: (cols: Int, rows: Int)? = nil
    ) {
        startProcess(
            executablePath: "/usr/bin/ssh",
            arguments: arguments,
            password: password,
            shellEnvironmentPath: nil,
            localeEnvironment: Self.terminalLocaleEnvironment(),
            initialWindowSize: initialWindowSize
        )
    }

    func startLocalShell(
        shellPath: String,
        arguments: [String],
        initialWindowSize: (cols: Int, rows: Int)? = nil
    ) {
        let resolvedShellPath = Self.preferredLocalShellPath(preferred: shellPath)
        startProcess(
            executablePath: resolvedShellPath,
            arguments: arguments,
            password: nil,
            shellEnvironmentPath: resolvedShellPath,
            localeEnvironment: Self.terminalLocaleEnvironment(),
            initialWindowSize: initialWindowSize
        )
    }

    private func startProcess(
        executablePath: String,
        arguments: [String],
        password: String?,
        shellEnvironmentPath: String?,
        localeEnvironment: [(String, String)] = [],
        initialWindowSize: (cols: Int, rows: Int)? = nil
    ) {
        terminate()
        pendingPassword = password
        authTranscript = ""
        didSendPassword = false
        didRequestPasswordResolution = false
        pendingPasswordSource = nil
        didLogRepeatedPasswordPrompt = false

        let normalizedWindowSize = Self.normalizedWindowSize(initialWindowSize)
        var windowSize = winsize(
            ws_row: UInt16(normalizedWindowSize.rows),
            ws_col: UInt16(normalizedWindowSize.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &windowSize)

        if pid < 0 {
            notifyDelegate { delegate in
                delegate.transportDidFail("无法创建 PTY")
            }
            return
        }

        if pid == 0 {
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            if let shellEnvironmentPath {
                // 本机终端应让 SHELL 与实际启动的 shell 保持一致，避免交互命令读到误导性的旧值。
                setenv("SHELL", shellEnvironmentPath, 1)
            }
            for (key, value) in Self.terminalProcessEnvironment(localeEnvironment: localeEnvironment) {
                setenv(key, value, 1)
            }
            chdir(NSHomeDirectory())

            var cStrings = ([executablePath] + arguments).map { strdup($0) }
            cStrings.append(nil)
            _ = cStrings.withUnsafeMutableBufferPointer { buffer in
                execvp(executablePath, buffer.baseAddress)
            }
            _exit(127)
        }

        masterFD = fd
        sshPID = pid
        activeProcessToken &+= 1
        let processToken = activeProcessToken
        zmodemDetector.reset()
        pendingTrigger = nil
        pendingData.removeAll(keepingCapacity: true)
        transferDirection = nil
        didSeeDownloadCompletionFrame = false
        isCancellingTransfer = false
        lastWindowSize = normalizedWindowSize
        debugTranscript.removeAll(keepingCapacity: true)
        lastDebugSnapshotPublishTime = nil

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        readSource.setEventHandler { [weak self] in
            self?.handleRead(expectedFD: fd, token: processToken)
        }
        readSource.resume()
        self.readSource = readSource

        let waitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        waitSource.setEventHandler { [weak self] in
            self?.handleExit(pid: pid, token: processToken)
        }
        waitSource.resume()
        self.waitSource = waitSource
    }

    private static func preferredLocalShellPath(preferred: String) -> String {
        // 优先使用产品定义的默认本机 shell；若当前机器没有该路径，再退回用户环境和常见 shell。
        let candidates = [
            preferred,
            ProcessInfo.processInfo.environment["SHELL"],
            "/bin/zsh",
            "/bin/bash"
        ]
        .compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return preferred
    }

    private static func terminalLocaleEnvironment() -> [(String, String)] {
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var localeVariables: [(String, String)] = []

        // Finder 启动的图形应用经常拿不到完整 locale；本地 shell 和 ssh 客户端都要显式带上 UTF-8，
        // 否则本机命令、以及依赖 LANG/LC_* 转发的远端 shell，都可能退回到 ASCII/C locale。
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = inheritedEnvironment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                localeVariables.append((key, value.replacingOccurrences(of: "\"", with: "")))
            }
        }

        if localeVariables.contains(where: { $0.0 == "LC_ALL" || $0.0 == "LANG" || $0.0 == "LC_CTYPE" }) {
            return localeVariables
        }

        return [
            ("LANG", "en_US.UTF-8"),
            ("LC_CTYPE", "UTF-8")
        ]
    }

    static func dockerPlainProgressEnvironment() -> [(String, String)] {
        [
            ("BUILDKIT_PROGRESS", "plain"),
            ("COMPOSE_PROGRESS", "plain")
        ]
    }

    private static func terminalProcessEnvironment(localeEnvironment: [(String, String)]) -> [(String, String)] {
        // Docker/Compose 在 TTY 中默认使用动态进度条，会频繁移动光标；ShellX 终端优先使用纯文本进度。
        localeEnvironment + dockerPlainProgressEnvironment()
    }

    static func normalizedWindowSize(_ proposedSize: (cols: Int, rows: Int)?) -> (cols: Int, rows: Int) {
        let defaultSize = (cols: 120, rows: 40)
        guard let proposedSize else { return defaultSize }

        // PTY 的 winsize 字段是 UInt16；这里先做边界收敛，避免异常布局尺寸溢出。
        return (
            cols: min(max(proposedSize.cols, 1), Int(UInt16.max)),
            rows: min(max(proposedSize.rows, 1), Int(UInt16.max))
        )
    }

    func send(_ data: Data, trackAsUserInput: Bool = true) {
        guard masterFD >= 0 else { return }
        if trackAsUserInput {
            recordUserInput(data)
        }
        _ = writeAll(data, to: masterFD)
    }

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        guard cols > 0, rows > 0 else { return }
        let normalizedWindowSize = Self.normalizedWindowSize((cols: cols, rows: rows))
        if let lastWindowSize,
           lastWindowSize.cols == normalizedWindowSize.cols,
           lastWindowSize.rows == normalizedWindowSize.rows {
            return
        }
        var windowSize = winsize(
            ws_row: UInt16(normalizedWindowSize.rows),
            ws_col: UInt16(normalizedWindowSize.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFD, TIOCSWINSZ, &windowSize) == 0 else {
            return
        }
        lastWindowSize = normalizedWindowSize
    }

    private func notifyDelegate(_ action: @escaping @MainActor (SSHPTYTransportDelegate) -> Void) {
        guard let delegate else { return }
        Task { @MainActor in
            action(delegate)
        }
    }

    func terminate() {
        cancelTransfer(sendCancel: false)

        activeProcessToken &+= 1
        let pid = sshPID
        sshPID = 0
        let fd = masterFD
        masterFD = -1
        cleanupReadResources()
        closeFileDescriptorIfNeeded(fd)

        guard pid != 0 else { return }
        kill(pid, SIGTERM)

        // 主动回收被关闭/重连的子进程，避免在 wait source 已取消后留下僵尸进程。
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, 0)
                if result == pid || result == -1 {
                    break
                }
            }
        }
    }

    func startUpload(from fileURLs: [URL]) {
        let sortedPaths = fileURLs
            .map(\.path)
            .filter { !$0.isEmpty }
            .sorted()
        guard !sortedPaths.isEmpty else { return }

        startTransfer(
            direction: .uploadToRemote,
            executableName: "sz",
            arguments: Self.zmodemUploadArguments(for: sortedPaths),
            totalFiles: sortedPaths.count
        )
    }

    func startDownload(to directoryURL: URL) {
        startTransfer(
            direction: .downloadFromRemote,
            executableName: "rz",
            arguments: Self.zmodemDownloadArguments(),
            currentDirectory: directoryURL,
            totalFiles: nil
        )
    }

    func cancelTransfer(sendCancel: Bool) {
        isCancellingTransfer = true
        if sendCancel {
            send(ZModemControlBytes.cancel)
        }

        helperOutputHandler?.cancel()
        helperErrorHandler?.cancel()
        helperOutputHandler = nil
        helperErrorHandler = nil

        helperStdIn?.fileHandleForWriting.closeFile()
        helperStdIn = nil
        helperStdOut = nil
        helperStdErr = nil

        if let helperProcess, helperProcess.isRunning {
            helperProcess.terminate()
        }
        helperProcess = nil
        transferDirection = nil
        progressParser = nil
        didSeeDownloadCompletionFrame = false
        pendingTrigger = nil
        pendingData.removeAll(keepingCapacity: true)
        zmodemDetector.reset()
        currentUserCommandBuffer = ""
        lastSubmittedUserCommand = nil
        pendingPassword = nil
        authTranscript = ""
        didSendPassword = false
        didRequestPasswordResolution = false
        pendingPasswordSource = nil
        didLogRepeatedPasswordPrompt = false
        lastWindowSize = nil
        debugTranscript.removeAll(keepingCapacity: true)
        lastDebugSnapshotPublishTime = nil
    }

    private func handleRead(expectedFD: Int32, token: UInt64) {
        guard token == activeProcessToken else { return }
        guard masterFD == expectedFD, expectedFD >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(expectedFD, &buffer, buffer.count)

        guard bytesRead > 0 else {
            return
        }

        let data = Data(buffer.prefix(bytesRead))
        updateDebugTranscript(with: data)
        if shouldHandlePasswordPrompt(from: data) {
            if pendingPassword != nil {
                sendPasswordIfNeeded()
            } else if !didRequestPasswordResolution {
                didRequestPasswordResolution = true
                notifyDelegate { delegate in
                    delegate.transportDidRequestPassword()
                }
            }
        }

        if let helperStdIn {
            if transferDirection == .downloadFromRemote,
               Self.containsDownloadCompletionFrame(in: data) {
                didSeeDownloadCompletionFrame = true
                helperStdIn.fileHandleForWriting.write(data)
                // 远端 `sz` 已发出结束帧后，本地 `rz` 应该尽快读到 EOF 并退出；
                // 否则 helper 会继续占着传输态，导致终端虽然已收到文件却仍无法操作。
                helperStdIn.fileHandleForWriting.closeFile()
                self.helperStdIn = nil
                return
            }
            helperStdIn.fileHandleForWriting.write(data)
            return
        }

        if pendingTrigger != nil {
            pendingData.append(data)
            return
        }

        if let trigger = zmodemDetector.consume(data, preferredDirection: preferredZModemDirection()) {
            pendingTrigger = trigger
            pendingData = Self.sanitizedTransferSeed(from: data, trigger: trigger)
            notifyDelegate { delegate in
                delegate.transportDidDetectZModem(trigger)
            }
            return
        }

        notifyDelegate { delegate in
            delegate.transportDidReceive(data)
        }
    }

    private func handleExit(pid: pid_t, token: UInt64) {
        var status: Int32 = 0
        let waitResult = waitpid(pid, &status, 0)

        guard waitResult == pid else {
            return
        }

        cleanupReadResources()
        if token == activeProcessToken, sshPID == pid {
            sshPID = 0
        }
        if token == activeProcessToken {
            closeFileDescriptorIfNeeded(masterFD)
            masterFD = -1
        }
        let exitCode: Int32?
        if Self.didExit(status) {
            exitCode = Self.exitStatus(status)
        } else if Self.didTerminateBySignal(status) {
            exitCode = 128 + Self.terminationSignal(status)
        } else {
            exitCode = nil
        }

        publishDebugSnapshot(force: true)
        notifyDelegate { delegate in
            delegate.transportDidTerminate(exitCode: exitCode)
        }
    }

    private func startTransfer(
        direction: ZModemTransferDirection,
        executableName: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        totalFiles: Int?
    ) {
        guard pendingTrigger != nil else { return }

        guard let executable = ZModemHelperLocator.path(named: executableName) else {
            pendingTrigger = nil
            let message = "本机未找到 \(executableName) 命令，请先安装 lrzsz"
            notifyDelegate { delegate in
                delegate.transportDidFail(message)
            }
            return
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        process.terminationHandler = { [weak self] process in
            self?.finishTransfer(process.terminationStatus)
        }

        helperProcess = process
        helperStdIn = stdinPipe
        helperStdOut = stdoutPipe
        helperStdErr = stderrPipe
        transferDirection = direction
        progressParser = ZModemProgressParser(direction: direction, totalFiles: totalFiles)
        didSeeDownloadCompletionFrame = false
        isCancellingTransfer = false

        helperOutputHandler = makeHelperReadSource(
            fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            sink: .master
        )
        helperErrorHandler = makeHelperReadSource(
            fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
            sink: .progress
        )
        helperOutputHandler?.resume()
        helperErrorHandler?.resume()

        do {
            try process.run()
            if !pendingData.isEmpty {
                stdinPipe.fileHandleForWriting.write(pendingData)
                pendingData.removeAll(keepingCapacity: true)
            }
            pendingTrigger = nil
        } catch {
            cancelTransfer(sendCancel: true)
            notifyDelegate { delegate in
                delegate.transportDidFail("启动 \(executableName) 失败：\(error.localizedDescription)")
            }
        }
    }

    private enum HelperSink {
        case master
        case progress
    }

    private func makeHelperReadSource(fileDescriptor: Int32, sink: HelperSink) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 32768)
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead > 0 else { return }
            let data = Data(buffer.prefix(bytesRead))
            switch sink {
            case .master:
                let data = Data(buffer.prefix(bytesRead))
                self.send(data, trackAsUserInput: false)
            case .progress:
                self.handleTransferProgress(data)
            }
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        return source
    }

    private func finishTransfer(_ status: Int32) {
        let wasCancellingTransfer = isCancellingTransfer
        helperOutputHandler?.cancel()
        helperErrorHandler?.cancel()
        helperOutputHandler = nil
        helperErrorHandler = nil

        helperStdIn?.fileHandleForWriting.closeFile()
        helperStdIn = nil
        helperStdOut = nil
        helperStdErr = nil
        helperProcess = nil
        pendingTrigger = nil
        pendingData.removeAll(keepingCapacity: true)
        zmodemDetector.reset()
        didSeeDownloadCompletionFrame = false
        currentUserCommandBuffer = ""
        lastSubmittedUserCommand = nil
        pendingPassword = nil
        authTranscript = ""
        didSendPassword = false
        didRequestPasswordResolution = false
        pendingPasswordSource = nil
        didLogRepeatedPasswordPrompt = false
        isCancellingTransfer = false

        let direction = transferDirection
        progressParser?.markCompleted()
        let finalProgress = progressParser
        progressParser = nil
        transferDirection = nil

        guard !wasCancellingTransfer else { return }

        let message: String
        if status == 0 {
            switch direction {
            case .uploadToRemote:
                message = Self.transferCompletionMessage(
                    direction: .uploadToRemote,
                    progress: finalProgress?.progress
                )
            case .downloadFromRemote:
                message = Self.transferCompletionMessage(
                    direction: .downloadFromRemote,
                    progress: finalProgress?.progress
                )
            case .none:
                message = "传输完成"
            }
        } else {
            message = "传输失败，退出码 \(status)"
        }

        notifyDelegate { delegate in
            delegate.transportDidFail(message)
        }
    }

    private func handleTransferProgress(_ data: Data) {
        guard var progressParser else { return }
        guard let progress = progressParser.consume(data) else { return }
        self.progressParser = progressParser
        notifyDelegate { delegate in
            delegate.transportDidUpdateZModemProgress(progress)
        }
    }

    private func cleanupReadResources() {
        readSource?.cancel()
        waitSource?.cancel()
        readSource = nil
        waitSource = nil
    }

    private func closeFileDescriptorIfNeeded(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = close(fd)
    }

    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
        guard !data.isEmpty else { return true }

        var didSucceed = true
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            var totalBytesWritten = 0
            while totalBytesWritten < rawBuffer.count {
                let remainingCount = rawBuffer.count - totalBytesWritten
                let currentAddress = baseAddress.advanced(by: totalBytesWritten)
                let writtenCount = write(fd, currentAddress, remainingCount)

                if writtenCount > 0 {
                    totalBytesWritten += writtenCount
                    continue
                }

                if writtenCount == -1 && errno == EINTR {
                    continue
                }

                didSucceed = false
                break
            }
        }

        return didSucceed
    }

    private func shouldHandlePasswordPrompt(from data: Data) -> Bool {
        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return false }

        // 仅保留认证早期的短窗口输出，避免把后续业务输出误判成密码提示。
        authTranscript.append(chunk.lowercased())
        if authTranscript.count > 512 {
            authTranscript = String(authTranscript.suffix(512))
        }

        let didDetectPrompt = Self.containsPasswordPrompt(in: authTranscript)

        guard didDetectPrompt else { return false }

        if didSendPassword {
            if !didLogRepeatedPasswordPrompt {
                recordSSHAuthDebugEvent("ssh.passwordPrompt.promptedAgainAfterAutofill")
                didLogRepeatedPasswordPrompt = true
            }
            return false
        }

        if didRequestPasswordResolution {
            return false
        }

        recordSSHAuthDebugEvent("ssh.passwordPrompt.detected")
        return true
    }

    private static func containsPasswordPrompt(in text: String) -> Bool {
        text.contains("password:")
            || text.contains("密码:")
            || text.contains("密码：")
            || text.contains("password for")
    }

    private func sendPasswordIfNeeded() {
        guard let pendingPassword, !didSendPassword else { return }
        let source = pendingPasswordSource?.rawValue ?? "unknown"
        recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.sent source=\(source) length=\(pendingPassword.count)")
        send(Data((pendingPassword + "\n").utf8), trackAsUserInput: false)
        didSendPassword = true
        // 密码已经提交后丢弃旧提示窗口，避免后续登录横幅被旧的 "password:" 片段误判为重复提示。
        authTranscript.removeAll(keepingCapacity: true)
        self.pendingPassword = nil
        pendingPasswordSource = nil
        didRequestPasswordResolution = false
    }

    func providePassword(_ password: String, source: SSHPasswordSource = .manual) {
        guard !password.isEmpty else { return }
        pendingPassword = password
        pendingPasswordSource = source
        recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.provide source=\(source.rawValue) length=\(password.count)")
        if Self.containsPasswordPrompt(in: authTranscript) {
            sendPasswordIfNeeded()
        }
    }

    func recordSSHAuthDebugEvent(_ event: String) {
        appendDebugLine("[SSHAuth] \(event)")
    }

    private func updateDebugTranscript(with data: Data) {
        let normalized = Self.debugString(from: data, maxBytes: maxDebugBytesPerRead)
        guard !normalized.isEmpty else { return }

        debugTranscript.append(normalized)
        publishDebugSnapshot(force: false)
    }

    private func appendDebugLine(_ line: String) {
        debugTranscript.append(line)
        if !line.hasSuffix("\n") {
            debugTranscript.append("\n")
        }
        publishDebugSnapshot(force: true)
    }

    private func publishDebugSnapshot(force: Bool) {
        if debugTranscript.count > maxDebugTranscriptLength {
            debugTranscript = String(debugTranscript.suffix(maxDebugTranscriptLength))
        }

        let now = DispatchTime.now()
        if !force,
           let lastDebugSnapshotPublishTime,
           now.uptimeNanoseconds - lastDebugSnapshotPublishTime.uptimeNanoseconds < minDebugSnapshotPublishIntervalNanoseconds {
            return
        }
        lastDebugSnapshotPublishTime = now

        let snapshot = debugTranscript
        notifyDelegate { delegate in
            delegate.transportDidUpdateDebugSnapshot(snapshot)
        }
    }

    private static func debugString(from data: Data, maxBytes: Int) -> String {
        let clippedData = data.count > maxBytes ? data.suffix(maxBytes) : data[...]
        return String(decoding: clippedData, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
            .replacingOccurrences(of: "\r", with: "<CR>\n")
            .replacingOccurrences(of: "\n", with: "<LF>\n")
            .replacingOccurrences(of: "\t", with: "<TAB>")
    }

    private func preferredZModemDirection() -> ZModemTransferDirection? {
        guard let lastSubmittedUserCommand else {
            return nil
        }
        return Self.preferredZModemDirection(from: lastSubmittedUserCommand)
    }

    private func recordUserInput(_ data: Data) {
        for byte in data {
            switch byte {
            case 0x08, 0x7F:
                if !currentUserCommandBuffer.isEmpty {
                    currentUserCommandBuffer.removeLast()
                }
            case 0x0D, 0x0A:
                let submitted = currentUserCommandBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !submitted.isEmpty {
                    lastSubmittedUserCommand = submitted
                }
                currentUserCommandBuffer.removeAll(keepingCapacity: true)
            case 0x20...0x7E:
                currentUserCommandBuffer.append(Character(UnicodeScalar(byte)))
                if currentUserCommandBuffer.count > 512 {
                    currentUserCommandBuffer = String(currentUserCommandBuffer.suffix(512))
                }
            default:
                continue
            }
        }
    }

    static func sanitizedTransferSeed(from data: Data, trigger: ZModemTrigger) -> Data {
        let marker: [UInt8]
        switch trigger {
        case .uploadRequest:
            marker = Array("**B01".utf8)
        case .downloadRequest:
            marker = Array("**B0".utf8)
        }

        let bytes = Array(data)
        guard let startIndex = bytes.firstRange(of: marker)?.lowerBound else {
            return data
        }
        return Data(bytes[startIndex...])
    }

    // `sz` 结束时远端会回送 `**B08...` 尾帧；此后本地 `rz` 再输出的少量协议字节
    // 很容易落回远端 shell，表现为 `**080...：未找到命令`。这里单独识别尾帧，
    // 在收尾阶段停止继续把 helper 的 stdout 回灌到远端。
    static func containsDownloadCompletionFrame(in data: Data) -> Bool {
        let normalized = String(
            decoding: data.filter { byte in
                switch byte {
                case 0x20...0x7E:
                    return true
                case 0x0A, 0x0D, 0x09:
                    return true
                default:
                    return false
                }
            },
            as: UTF8.self
        )
        return normalized.contains("**B08")
    }

    static func preferredZModemDirection(from submittedCommand: String) -> ZModemTransferDirection? {
        let command = submittedCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !command.isEmpty else { return nil }

        // 终端里常见的是 `tmux ... 'sz file'`、`bash -lc "rz"` 这类包装命令；
        // 这里不要求命令必须位于行首，只取最后一个独立的 rz/sz token 作为方向线索。
        let pattern = #"(?<![\w/\.-])(rz|sz)(?=(?:\s|$|["';|&)\]}]))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        let matches = regex.matches(in: command, options: [], range: range)
        guard let lastMatch = matches.last,
              let valueRange = Range(lastMatch.range(at: 1), in: command) else {
            return nil
        }

        switch String(command[valueRange]) {
        case "rz":
            return .uploadToRemote
        case "sz":
            return .downloadFromRemote
        default:
            return nil
        }
    }

    static func zmodemUploadArguments(for filePaths: [String]) -> [String] {
        // 之前把 lrzsz 强行限制在 4 KiB 缓冲，会在低延迟局域网里明显压低吞吐；
        // 这里改回工具默认协商参数，并显式开启 verbose，让 stderr 稳定输出进度信息。
        ["--escape", "--binary", "--verbose", "--verbose"] + filePaths
    }

    static func zmodemDownloadArguments() -> [String] {
        ["--rename", "--escape", "--binary", "--verbose", "--verbose"]
    }

    private static func transferCompletionMessage(
        direction: ZModemTransferDirection,
        progress: ZModemTransferProgress?
    ) -> String {
        let fallback = direction == .uploadToRemote ? "文件上传完成" : "文件下载完成"
        guard let progress else { return fallback }

        let fileCount = max(progress.completedFiles, progress.totalFiles ?? 0)
        if fileCount > 1 {
            return direction == .uploadToRemote
                ? "已完成上传 \(fileCount) 个文件"
                : "已完成下载 \(fileCount) 个文件"
        }

        if let currentFileName = progress.currentFileName, !currentFileName.isEmpty {
            return direction == .uploadToRemote
                ? "已完成上传 \(currentFileName)"
                : "已完成下载 \(currentFileName)"
        }

        return fallback
    }
}
