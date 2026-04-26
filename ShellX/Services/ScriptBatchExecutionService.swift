import Foundation

final class ScriptBatchExecutionService: @unchecked Sendable {
    enum TerminationReason: Sendable {
        case manual
        case timeout(seconds: Int)
    }

    static let defaultProcessTimeoutSeconds = 3600

    // 批量执行只保留最近一段输出，避免大量主机同时返回大日志时占满内存。
    private let maxOutputBytes = 131_072
    private let knownHostsService = KnownHostsService()
    private let stateLock = NSLock()
    private var runningProcesses: [UUID: Process] = [:]
    private var terminationReasons: [UUID: TerminationReason] = [:]

    func execute(
        script: UserScript,
        session: SSHSessionProfile,
        arguments scriptArguments: [String] = [],
        timeoutSeconds: Int = defaultProcessTimeoutSeconds
    ) async -> (status: ScriptExecutionStatus, output: String) {
        // 非交互批量任务不能安全处理密码提示，避免任务卡在远端认证阶段。
        guard session.authMethod != .password else {
            return (
                .failed("批量脚本暂不支持账号密码认证会话，请改用 SSH Agent 或私钥认证。"),
                ""
            )
        }

        do {
            let knownHostsPath = try KnownHostsService.defaultKnownHostsFilePath()
            let trustState = try await knownHostsService.evaluate(host: session.host, port: session.port)
            guard trustState == .trusted else {
                return (
                    .failed("主机指纹尚未信任，请先打开该会话并确认主机指纹后再批量执行脚本。"),
                    ""
                )
            }
            return try await runSSHProcess(
                scriptContent: script.content,
                session: session,
                knownHostsPath: knownHostsPath,
                scriptArguments: scriptArguments,
                timeoutSeconds: max(1, timeoutSeconds)
            )
        } catch {
            return (.failed(error.localizedDescription), "")
        }
    }

    func terminate(sessionID: UUID) {
        terminate(sessionIDs: [sessionID])
    }

    func terminate(sessionIDs: [UUID]) {
        let processes = stateLock.withLock { () -> [Process] in
            sessionIDs.compactMap { sessionID in
                guard let process = runningProcesses[sessionID] else { return nil }
                terminationReasons[sessionID] = .manual
                return process
            }
        }

        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    func terminateAllRunningProcesses() {
        let processes = stateLock.withLock { () -> [Process] in
            for sessionID in runningProcesses.keys {
                terminationReasons[sessionID] = .manual
            }
            return Array(runningProcesses.values)
        }

        for process in processes where process.isRunning {
            process.terminate()
        }
    }

    private func runSSHProcess(
        scriptContent: String,
        session: SSHSessionProfile,
        knownHostsPath: String,
        scriptArguments: [String],
        timeoutSeconds: Int
    ) async throws -> (status: ScriptExecutionStatus, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let inputPipe = Pipe()
            let outputBuffer = LockedOutputBuffer(maxBytes: maxOutputBytes)
            let timeoutTask = DispatchWorkItem {
                if process.isRunning {
                    self.markTerminationReason(.timeout(seconds: timeoutSeconds), for: session.id)
                    process.terminate()
                }
            }

            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.sshArguments(
                for: session,
                userKnownHostsPath: knownHostsPath,
                scriptArguments: scriptArguments
            )
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            process.standardInput = inputPipe

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputBuffer.append(data)
            }

            process.terminationHandler = { finishedProcess in
                timeoutTask.cancel()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let trailingData = outputPipe.fileHandleForReading.availableData
                if !trailingData.isEmpty {
                    outputBuffer.append(trailingData)
                }
                let terminationReason = self.unregisterProcess(for: session.id)
                if let terminationReason {
                    outputBuffer.append("\n[ShellX] \(Self.terminationMessage(for: terminationReason))")
                }
                let output = outputBuffer.stringValue()
                if let terminationReason {
                    continuation.resume(returning: (.failed(Self.terminationStatusMessage(for: terminationReason)), output))
                } else if finishedProcess.terminationStatus == 0 {
                    continuation.resume(returning: (.succeeded, output))
                } else {
                    continuation.resume(returning: (
                        .failed("退出码 \(finishedProcess.terminationStatus)"),
                        output
                    ))
                }
            }

            do {
                try process.run()
                register(process: process, for: session.id)
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(timeoutSeconds),
                    execute: timeoutTask
                )
                inputPipe.fileHandleForWriting.write(Data(scriptContent.utf8))
                inputPipe.fileHandleForWriting.write(Data("\n".utf8))
                try? inputPipe.fileHandleForWriting.close()
            } catch {
                timeoutTask.cancel()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func register(process: Process, for sessionID: UUID) {
        stateLock.withLock {
            runningProcesses[sessionID] = process
            terminationReasons.removeValue(forKey: sessionID)
        }
    }

    private func unregisterProcess(for sessionID: UUID) -> TerminationReason? {
        stateLock.withLock {
            runningProcesses.removeValue(forKey: sessionID)
            return terminationReasons.removeValue(forKey: sessionID)
        }
    }

    private func markTerminationReason(_ reason: TerminationReason, for sessionID: UUID) {
        stateLock.withLock {
            terminationReasons[sessionID] = reason
        }
    }

    private static func terminationMessage(for reason: TerminationReason) -> String {
        switch reason {
        case .manual:
            return "脚本执行已被手动终止。"
        case .timeout(let seconds):
            return "脚本执行超过 \(seconds) 秒，已自动终止。"
        }
    }

    private static func terminationStatusMessage(for reason: TerminationReason) -> String {
        switch reason {
        case .manual:
            return "已终止"
        case .timeout(let seconds):
            return "执行超时（\(seconds) 秒）"
        }
    }

    static func sshArguments(
        for session: SSHSessionProfile,
        userKnownHostsPath: String,
        scriptArguments: [String] = []
    ) -> [String] {
        let escapedKnownHostsPath = KnownHostsService.escapedOpenSSHConfigPath(userKnownHostsPath)
        var args = [
            "-T",
            "-p", "\(session.port)",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "UserKnownHostsFile=\(escapedKnownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes",
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
        }

        args.append(session.destination)
        args.append(remoteShellCommand(scriptArguments: scriptArguments))
        return args
    }

    static func parseArgumentText(_ text: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var isEscaping = false

        for character in text {
            if isEscaping {
                current.append(character)
                hasCurrent = true
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                hasCurrent = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                    hasCurrent = true
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
                continue
            }

            if character.isWhitespace {
                if hasCurrent {
                    arguments.append(current)
                    current = ""
                    hasCurrent = false
                }
                continue
            }

            current.append(character)
            hasCurrent = true
        }

        if isEscaping {
            throw ScriptArgumentParseError.trailingEscape
        }
        if let unclosedQuote = quote {
            throw ScriptArgumentParseError.unclosedQuote(unclosedQuote)
        }
        if hasCurrent {
            arguments.append(current)
        }

        return arguments
    }

    static func remoteShellCommand(scriptArguments: [String]) -> String {
        (["sh", "-s", "--"] + scriptArguments.map { shellQuote($0) }).joined(separator: " ")
    }

    private static func shellQuote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let quoted = argument.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(quoted)'"
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

enum ScriptArgumentParseError: LocalizedError, Equatable {
    case trailingEscape
    case unclosedQuote(Character)

    var errorDescription: String? {
        switch self {
        case .trailingEscape:
            return "参数不能以反斜杠结尾，请补全转义字符或删除末尾反斜杠。"
        case .unclosedQuote(let quote):
            return "参数中的 \(quote) 引号未闭合，请补齐后再执行。"
        }
    }
}

private final class LockedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var data = Data()
    private var didTruncate = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }

        data.append(newData)
        guard data.count > maxBytes else { return }
        data = Data(data.suffix(maxBytes))
        didTruncate = true
    }

    func append(_ string: String) {
        append(Data(string.utf8))
    }

    func stringValue() -> String {
        lock.lock()
        defer { lock.unlock() }

        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if didTruncate {
            return "[ShellX] 输出过长，仅保留最后 \(maxBytes / 1024) KiB。\n\(text)"
        }
        return text
    }
}
