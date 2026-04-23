import Foundation

struct ScriptBatchExecutionService: Sendable {
    // 批量执行只保留最近一段输出，避免大量主机同时返回大日志时占满内存。
    private let maxOutputBytes = 131_072
    private let processTimeoutSeconds: TimeInterval = 300

    func execute(
        script: UserScript,
        session: SSHSessionProfile,
        arguments scriptArguments: [String] = []
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
            return try await runSSHProcess(
                scriptContent: script.content,
                session: session,
                knownHostsPath: knownHostsPath,
                scriptArguments: scriptArguments
            )
        } catch {
            return (.failed(error.localizedDescription), "")
        }
    }

    private func runSSHProcess(
        scriptContent: String,
        session: SSHSessionProfile,
        knownHostsPath: String,
        scriptArguments: [String]
    ) async throws -> (status: ScriptExecutionStatus, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let inputPipe = Pipe()
            let outputBuffer = LockedOutputBuffer(maxBytes: maxOutputBytes)
            let timeoutTask = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    outputBuffer.append("\n[ShellX] 执行超过 300 秒，已终止。")
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
                let output = outputBuffer.stringValue()
                if finishedProcess.terminationStatus == 0 {
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
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + processTimeoutSeconds,
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

    static func sshArguments(
        for session: SSHSessionProfile,
        userKnownHostsPath: String,
        scriptArguments: [String] = []
    ) -> [String] {
        var args = [
            "-T",
            "-p", "\(session.port)",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "UserKnownHostsFile=\(userKnownHostsPath)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=no",
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
