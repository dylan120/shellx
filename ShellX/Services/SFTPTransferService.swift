import Darwin
import Foundation

@MainActor
protocol SFTPTransferServiceDelegate: AnyObject {
    func sftpTransferDidStart(message: String)
    func sftpTransferDidComplete(message: String)
    func sftpTransferDidFail(message: String)
}

enum SFTPOperation: Equatable {
    case upload(localURL: URL, remoteDirectory: String)
    case downloadFile(remotePath: String, localDirectory: URL)
    case downloadDirectory(remotePath: String, localDirectory: URL)

    var startMessage: String {
        switch self {
        case .upload(let localURL, _):
            return "正在通过 SFTP 上传 \(localURL.lastPathComponent)。"
        case .downloadFile(let remotePath, _):
            return "正在通过 SFTP 下载文件 \(remotePath)。"
        case .downloadDirectory(let remotePath, _):
            return "正在通过 SFTP 下载文件夹 \(remotePath)。"
        }
    }

    var successMessage: String {
        switch self {
        case .upload(let localURL, _):
            return "SFTP 上传完成：\(localURL.lastPathComponent)"
        case .downloadFile(let remotePath, _):
            return "SFTP 下载完成：\(remotePath)"
        case .downloadDirectory(let remotePath, _):
            return "SFTP 下载完成：\(remotePath)"
        }
    }
}

final class SFTPTransferService {
    weak var delegate: SFTPTransferServiceDelegate?

    private let ioQueue = DispatchQueue(label: "com.shellx.sftp.io", qos: .userInitiated)
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private var pendingPassword: String?
    private var didSendPassword = false
    private var didSendCommands = false
    private var transcript = ""
    private var operation: SFTPOperation?

    deinit {
        terminate()
    }

    func start(
        session: SSHSessionProfile,
        operation: SFTPOperation,
        knownHostsPath: String,
        password: String?
    ) {
        terminate()

        self.operation = operation
        pendingPassword = password
        didSendPassword = false
        didSendCommands = false
        transcript.removeAll(keepingCapacity: true)

        var windowSize = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &windowSize)

        if pid < 0 {
            notifyDelegate { delegate in
                delegate.sftpTransferDidFail(message: "无法创建 SFTP PTY")
            }
            return
        }

        if pid == 0 {
            chdir(NSHomeDirectory())

            let arguments = Self.sftpArguments(
                for: session,
                userKnownHostsPath: knownHostsPath
            )
            var cStrings = (["/usr/bin/sftp"] + arguments).map { strdup($0) }
            cStrings.append(nil)
            _ = cStrings.withUnsafeMutableBufferPointer { buffer in
                execvp("/usr/bin/sftp", buffer.baseAddress)
            }
            _exit(127)
        }

        masterFD = fd
        childPID = pid

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

        notifyDelegate { delegate in
            delegate.sftpTransferDidStart(message: operation.startMessage)
        }
    }

    func terminate() {
        if childPID != 0 {
            kill(childPID, SIGTERM)
        }
        cleanup()
        pendingPassword = nil
        didSendPassword = false
        didSendCommands = false
        transcript.removeAll(keepingCapacity: true)
        operation = nil
    }

    static func sftpArguments(
        for session: SSHSessionProfile,
        userKnownHostsPath: String,
        strictHostKeyChecking: String = "no"
    ) -> [String] {
        var args = [
            "-P", "\(session.port)",
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
        return args
    }

    static func commandScript(for operation: SFTPOperation) -> String {
        switch operation {
        case .upload(let localURL, let remoteDirectory):
            let localPath = quote(localURL.path)
            let remotePath = quote(normalizedRemotePath(remoteDirectory))
            let command = localURL.hasDirectoryPath ? "put -r \(localPath) \(remotePath)" : "put \(localPath) \(remotePath)"
            return command + "\nbye\n"
        case .downloadFile(let remotePath, let localDirectory):
            return "get \(quote(normalizedRemotePath(remotePath))) \(quote(localDirectory.path))\nbye\n"
        case .downloadDirectory(let remotePath, let localDirectory):
            return "get -r \(quote(normalizedRemotePath(remotePath))) \(quote(localDirectory.path))\nbye\n"
        }
    }

    private static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : trimmed
    }

    private func handleRead() {
        guard masterFD >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 16384)
        let bytesRead = read(masterFD, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let data = Data(buffer.prefix(bytesRead))
        let chunk = String(decoding: data, as: UTF8.self)
        transcript.append(chunk)
        trimTranscriptIfNeeded()

        if shouldAutoFillPassword(from: data) {
            sendPasswordIfNeeded()
        }

        if isSFTPPromptVisible(in: chunk) {
            sendCommandsIfNeeded()
        }
    }

    private func handleExit() {
        var status: Int32 = 0
        _ = waitpid(childPID, &status, 0)

        let exitCode: Int32?
        if (status & 0o177) == 0 {
            exitCode = (status >> 8) & 0xFF
        } else {
            exitCode = nil
        }

        let operation = self.operation
        cleanup()
        pendingPassword = nil
        didSendPassword = false
        didSendCommands = false
        self.operation = nil

        let transcript = cleanedTranscript()

        notifyDelegate { delegate in
            if exitCode == 0, let operation {
                delegate.sftpTransferDidComplete(message: operation.successMessage)
            } else {
                let message = transcript.isEmpty ? "SFTP 传输失败" : "SFTP 传输失败：\(transcript)"
                delegate.sftpTransferDidFail(message: message)
            }
        }
    }

    private func cleanup() {
        readSource?.cancel()
        waitSource?.cancel()
        readSource = nil
        waitSource = nil
        childPID = 0
        masterFD = -1
    }

    private func notifyDelegate(_ action: @escaping @MainActor (SFTPTransferServiceDelegate) -> Void) {
        guard let delegate else { return }
        Task { @MainActor in
            action(delegate)
        }
    }

    private func shouldAutoFillPassword(from data: Data) -> Bool {
        guard pendingPassword != nil, !didSendPassword else { return false }
        let chunk = String(decoding: data, as: UTF8.self).lowercased()
        return chunk.contains("password:") || chunk.contains("密码")
    }

    private func sendPasswordIfNeeded() {
        guard let pendingPassword, !didSendPassword else { return }
        send(Data((pendingPassword + "\n").utf8))
        didSendPassword = true
    }

    private func sendCommandsIfNeeded() {
        guard !didSendCommands, let operation else { return }
        send(Data(Self.commandScript(for: operation).utf8))
        didSendCommands = true
    }

    private func send(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { bytes in
            _ = write(masterFD, bytes.baseAddress, bytes.count)
        }
    }

    private func isSFTPPromptVisible(in chunk: String) -> Bool {
        chunk.lowercased().contains("sftp>")
    }

    private func trimTranscriptIfNeeded() {
        if transcript.count > 8000 {
            transcript.removeFirst(transcript.count - 8000)
        }
    }

    private func cleanedTranscript() -> String {
        transcript
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "sftp>" }
            .suffix(8)
            .joined(separator: " | ")
    }
}
