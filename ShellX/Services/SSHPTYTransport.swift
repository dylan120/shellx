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
    private var pendingPassword: String?
    private var pendingPasswordSource: SSHPasswordSource?
    private var authTranscript = ""
    private var didSendPassword = false
    private var didRequestPasswordResolution = false
    private var didLogRepeatedPasswordPrompt = false
    private var lastWindowSize: (cols: Int, rows: Int)?
    private var debugTranscript = ""
    private let maxDebugTranscriptLength = 65536
    private var currentUserCommandBuffer = ""
    private var lastSubmittedUserCommand: String?

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

    func start(arguments: [String], password: String? = nil) {
        startProcess(
            executablePath: "/usr/bin/ssh",
            arguments: arguments,
            password: password
        )
    }

    func startLocalShell(shellPath: String, arguments: [String]) {
        startProcess(
            executablePath: Self.preferredLocalShellPath(preferred: shellPath),
            arguments: arguments,
            password: nil
        )
    }

    private func startProcess(
        executablePath: String,
        arguments: [String],
        password: String?
    ) {
        terminate()
        pendingPassword = password
        authTranscript = ""
        didSendPassword = false
        didRequestPasswordResolution = false
        pendingPasswordSource = nil
        didLogRepeatedPasswordPrompt = false

        var windowSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
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
        zmodemDetector.reset()
        pendingTrigger = nil
        pendingData.removeAll(keepingCapacity: true)
        transferDirection = nil
        didSeeDownloadCompletionFrame = false
        lastWindowSize = nil
        debugTranscript.removeAll(keepingCapacity: true)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        readSource.setEventHandler { [weak self] in
            self?.handleRead()
        }
        readSource.setCancelHandler { [fd] in
            close(fd)
        }
        readSource.resume()
        self.readSource = readSource

        let waitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        waitSource.setEventHandler { [weak self] in
            self?.handleExit()
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

    func send(_ data: Data, trackAsUserInput: Bool = true) {
        guard masterFD >= 0 else { return }
        if trackAsUserInput {
            recordUserInput(data)
        }
        data.withUnsafeBytes { bytes in
            _ = write(masterFD, bytes.baseAddress, bytes.count)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        guard cols > 0, rows > 0 else { return }
        if let lastWindowSize, lastWindowSize.cols == cols, lastWindowSize.rows == rows {
            return
        }
        var windowSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &windowSize)
        lastWindowSize = (cols, rows)
    }

    private func notifyDelegate(_ action: @escaping @MainActor (SSHPTYTransportDelegate) -> Void) {
        guard let delegate else { return }
        Task { @MainActor in
            action(delegate)
        }
    }

    func terminate() {
        cancelTransfer(sendCancel: false)

        if sshPID != 0 {
            kill(sshPID, SIGTERM)
        }

        cleanupReadResources()
        sshPID = 0
        masterFD = -1
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
            arguments: sortedPaths + ["--escape", "--binary", "--bufsize", "4096"],
            totalFiles: sortedPaths.count
        )
    }

    func startDownload(to directoryURL: URL) {
        startTransfer(
            direction: .downloadFromRemote,
            executableName: "rz",
            arguments: ["--rename", "--escape", "--binary", "--bufsize", "4096"],
            currentDirectory: directoryURL,
            totalFiles: nil
        )
    }

    func cancelTransfer(sendCancel: Bool) {
        if sendCancel {
            send(ZModemControlBytes.cancel)
        }

        helperOutputHandler?.cancel()
        helperErrorHandler?.cancel()
        helperOutputHandler = nil
        helperErrorHandler = nil

        helperStdIn?.fileHandleForWriting.closeFile()
        helperStdOut?.fileHandleForReading.closeFile()
        helperStdErr?.fileHandleForReading.closeFile()
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
    }

    private func handleRead() {
        guard masterFD >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(masterFD, &buffer, buffer.count)

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

    private func handleExit() {
        var status: Int32 = 0
        waitpid(sshPID, &status, 0)

        cleanupReadResources()
        let exitCode: Int32?
        if Self.didExit(status) {
            exitCode = Self.exitStatus(status)
        } else if Self.didTerminateBySignal(status) {
            exitCode = 128 + Self.terminationSignal(status)
        } else {
            exitCode = nil
        }

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

        let direction = transferDirection
        progressParser?.markCompleted()
        let finalProgress = progressParser
        progressParser = nil
        transferDirection = nil

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

    private func shouldHandlePasswordPrompt(from data: Data) -> Bool {
        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return false }

        // 仅保留认证早期的短窗口输出，避免把后续业务输出误判成密码提示。
        authTranscript.append(chunk.lowercased())
        if authTranscript.count > 512 {
            authTranscript = String(authTranscript.suffix(512))
        }

        let didDetectPrompt = authTranscript.contains("password:")
            || authTranscript.contains("密码:")
            || authTranscript.contains("密码：")
            || authTranscript.contains("password for")

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

    private func sendPasswordIfNeeded() {
        guard let pendingPassword, !didSendPassword else { return }
        let source = pendingPasswordSource?.rawValue ?? "unknown"
        recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.sent source=\(source) length=\(pendingPassword.count)")
        send(Data((pendingPassword + "\n").utf8), trackAsUserInput: false)
        didSendPassword = true
        self.pendingPassword = nil
        pendingPasswordSource = nil
        didRequestPasswordResolution = false
    }

    func providePassword(_ password: String, source: SSHPasswordSource = .manual) {
        guard !password.isEmpty else { return }
        pendingPassword = password
        pendingPasswordSource = source
        recordSSHAuthDebugEvent("ssh.passwordPrompt.autofill.provide source=\(source.rawValue) length=\(password.count)")
        if authTranscript.contains("password:")
            || authTranscript.contains("密码:")
            || authTranscript.contains("密码：")
            || authTranscript.contains("password for") {
            sendPasswordIfNeeded()
        }
    }

    func recordSSHAuthDebugEvent(_ event: String) {
        appendDebugLine("[SSHAuth] \(event)")
    }

    private func updateDebugTranscript(with data: Data) {
        let normalized = Self.debugString(from: data)
        guard !normalized.isEmpty else { return }

        debugTranscript.append(normalized)
        publishDebugSnapshot()
    }

    private func appendDebugLine(_ line: String) {
        debugTranscript.append(line)
        if !line.hasSuffix("\n") {
            debugTranscript.append("\n")
        }
        publishDebugSnapshot()
    }

    private func publishDebugSnapshot() {
        if debugTranscript.count > maxDebugTranscriptLength {
            debugTranscript = String(debugTranscript.suffix(maxDebugTranscriptLength))
        }

        let snapshot = debugTranscript
        notifyDelegate { delegate in
            delegate.transportDidUpdateDebugSnapshot(snapshot)
        }
    }

    private static func debugString(from data: Data) -> String {
        var result = ""
        result.reserveCapacity(data.count * 2)

        for byte in data {
            switch byte {
            case 0x1B:
                result.append("<ESC>")
            case 0x0D:
                result.append("<CR>\n")
            case 0x0A:
                result.append("<LF>\n")
            case 0x09:
                result.append("<TAB>")
            case 0x20...0x7E:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result.append(String(format: "<0x%02X>", byte))
            }
        }

        return result
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
