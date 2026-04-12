import Darwin
import Foundation

protocol SSHPTYTransportDelegate: AnyObject {
    func transportDidReceive(_ data: Data)
    func transportDidTerminate(exitCode: Int32?)
    func transportDidDetectZModem(_ trigger: ZModemTrigger)
    func transportDidFail(_ message: String)
    func transportDidUpdateDebugSnapshot(_ snapshot: String)
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
    private var pendingPassword: String?
    private var authTranscript = ""
    private var didSendPassword = false
    private var lastWindowSize: (cols: Int, rows: Int)?
    private var debugTranscript = ""
    private let maxDebugTranscriptLength = 65536

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
        terminate()
        pendingPassword = password
        authTranscript = ""
        didSendPassword = false

        var windowSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &windowSize)

        if pid < 0 {
            delegate?.transportDidFail("无法创建 PTY")
            return
        }

        if pid == 0 {
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            chdir(NSHomeDirectory())

            var cStrings = (["/usr/bin/ssh"] + arguments).map { strdup($0) }
            cStrings.append(nil)
            cStrings.withUnsafeMutableBufferPointer { buffer in
                execvp("/usr/bin/ssh", buffer.baseAddress)
            }
            _exit(127)
        }

        masterFD = fd
        sshPID = pid
        zmodemDetector.reset()
        pendingTrigger = nil
        pendingData.removeAll(keepingCapacity: true)
        transferDirection = nil
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

    func send(_ data: Data) {
        guard masterFD >= 0 else { return }
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
        ioctl(masterFD, TIOCSWINSZ, &windowSize)
        lastWindowSize = (cols, rows)
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

    func startUpload(from fileURL: URL) {
        startTransfer(
            direction: .uploadToRemote,
            executableName: "sz",
            arguments: [fileURL.path, "--escape", "--binary", "--bufsize", "4096"]
        )
    }

    func startDownload(to directoryURL: URL) {
        startTransfer(
            direction: .downloadFromRemote,
            executableName: "rz",
            arguments: ["--rename", "--escape", "--binary", "--bufsize", "4096"],
            currentDirectory: directoryURL
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
        pendingTrigger = nil
        pendingData.removeAll(keepingCapacity: true)
        zmodemDetector.reset()
        pendingPassword = nil
        authTranscript = ""
        didSendPassword = false
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
        if shouldAutoFillPassword(from: data) {
            sendPasswordIfNeeded()
        }

        if let helperStdIn {
            helperStdIn.fileHandleForWriting.write(data)
            return
        }

        if pendingTrigger != nil {
            pendingData.append(data)
            return
        }

        if let trigger = zmodemDetector.consume(data) {
            pendingTrigger = trigger
            pendingData = data
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.transportDidDetectZModem(trigger)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.transportDidReceive(data)
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

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.transportDidTerminate(exitCode: exitCode)
        }
    }

    private func startTransfer(
        direction: ZModemTransferDirection,
        executableName: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) {
        guard pendingTrigger != nil else { return }

        guard let executable = ZModemHelperLocator.path(named: executableName) else {
            pendingTrigger = nil
            let message = "本机未找到 \(executableName) 命令，请先安装 lrzsz"
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.transportDidFail(message)
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

        helperOutputHandler = makeHelperReadSource(
            fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor,
            sink: .master
        )
        helperErrorHandler = makeHelperReadSource(
            fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor,
            sink: .discard
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
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.transportDidFail("启动 \(executableName) 失败：\(error.localizedDescription)")
            }
        }
    }

    private enum HelperSink {
        case master
        case discard
    }

    private func makeHelperReadSource(fileDescriptor: Int32, sink: HelperSink) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 32768)
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead > 0 else { return }
            if sink == .master {
                let data = Data(buffer.prefix(bytesRead))
                self.send(data)
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
        pendingPassword = nil
        authTranscript = ""
        didSendPassword = false

        let direction = transferDirection
        transferDirection = nil

        let message: String
        if status == 0 {
            switch direction {
            case .uploadToRemote:
                message = "文件上传完成"
            case .downloadFromRemote:
                message = "文件下载完成"
            case .none:
                message = "传输完成"
            }
        } else {
            message = "传输失败，退出码 \(status)"
        }

        DispatchQueue.main.async { [weak self] in
            if status == 0 {
                self?.delegate?.transportDidFail(message)
            } else {
                self?.delegate?.transportDidFail(message)
            }
        }
    }

    private func cleanupReadResources() {
        readSource?.cancel()
        waitSource?.cancel()
        readSource = nil
        waitSource = nil
    }

    private func shouldAutoFillPassword(from data: Data) -> Bool {
        guard pendingPassword != nil, !didSendPassword else { return false }

        let chunk = String(decoding: data, as: UTF8.self)
        guard !chunk.isEmpty else { return false }

        // 仅保留认证早期的短窗口输出，避免把后续业务输出误判成密码提示。
        authTranscript.append(chunk.lowercased())
        if authTranscript.count > 512 {
            authTranscript = String(authTranscript.suffix(512))
        }

        return authTranscript.contains("password:")
            || authTranscript.contains("密码:")
            || authTranscript.contains("密码：")
    }

    private func sendPasswordIfNeeded() {
        guard let pendingPassword, !didSendPassword else { return }
        send(Data((pendingPassword + "\n").utf8))
        didSendPassword = true
        self.pendingPassword = nil
    }

    private func updateDebugTranscript(with data: Data) {
        let normalized = Self.debugString(from: data)
        guard !normalized.isEmpty else { return }

        debugTranscript.append(normalized)
        if debugTranscript.count > maxDebugTranscriptLength {
            debugTranscript = String(debugTranscript.suffix(maxDebugTranscriptLength))
        }

        let snapshot = debugTranscript
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.transportDidUpdateDebugSnapshot(snapshot)
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
}
