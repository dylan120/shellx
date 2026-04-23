import Foundation

enum KnownHostTrustState: Equatable {
    case trusted
    case prompt(KnownHostPrompt)
}

struct KnownHostPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        case unknown
        case updated
        case changed
    }

    let id = UUID()
    let host: String
    let port: Int
    let kind: Kind
    let scannedLines: [String]
    let newFingerprints: [String]
    let existingFingerprints: [String]
}

actor KnownHostsService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func evaluate(host: String, port: Int) async throws -> KnownHostTrustState {
        let storedLines = try trustedLines(for: host, port: port)
        if Self.canTrustExistingRecordWithoutPreScan(storedLines: storedLines) {
            return .trusted
        }

        let scannedLines: [String]
        do {
            scannedLines = try await scanHostKeys(host: host, port: port)
        } catch {
            if Self.canTrustExistingRecordWhenScanFails(storedLines: storedLines) {
                return .trusted
            }
            throw error
        }

        guard !scannedLines.isEmpty else {
            if Self.canTrustExistingRecordWhenScanFails(storedLines: storedLines) {
                return .trusted
            }
            throw KnownHostsError.scanFailed(
                Self.scanFailureDescription(
                    host: host,
                    port: port,
                    preferredAlgorithms: "ed25519,ecdsa,rsa",
                    failureDetails: ["ssh-keyscan 未返回可用主机公钥行。"]
                )
            )
        }

        let newFingerprints = try scannedLines.map(fingerprint)
        let existingFingerprints = try storedLines.map(fingerprint)

        return Self.classifyTrust(
            host: host,
            port: port,
            scannedLines: scannedLines,
            newFingerprints: newFingerprints,
            existingFingerprints: existingFingerprints
        )
    }

    nonisolated static func classifyTrust(
        host: String,
        port: Int,
        scannedLines: [String],
        newFingerprints: [String],
        existingFingerprints: [String]
    ) -> KnownHostTrustState {
        if existingFingerprints.isEmpty {
            return .prompt(
                KnownHostPrompt(
                    host: host,
                    port: port,
                    kind: .unknown,
                    scannedLines: scannedLines,
                    newFingerprints: newFingerprints,
                    existingFingerprints: []
                )
            )
        }

        let existingSet = Set(existingFingerprints)
        let newSet = Set(newFingerprints)

        if existingSet.intersection(newSet).isEmpty {
            return .prompt(
                KnownHostPrompt(
                    host: host,
                    port: port,
                    kind: .changed,
                    scannedLines: scannedLines,
                    newFingerprints: newFingerprints,
                    existingFingerprints: existingFingerprints
                )
            )
        }

        if !newSet.isSubset(of: existingSet) {
            return .prompt(
                KnownHostPrompt(
                    host: host,
                    port: port,
                    kind: .updated,
                    scannedLines: scannedLines,
                    newFingerprints: newFingerprints,
                    existingFingerprints: existingFingerprints
                )
            )
        }

        return .trusted
    }

    nonisolated static func canTrustExistingRecordWhenScanFails(storedLines: [String]) -> Bool {
        !storedLines.isEmpty
    }

    nonisolated static func canTrustExistingRecordWithoutPreScan(storedLines: [String]) -> Bool {
        !storedLines.isEmpty
    }

    func trust(_ prompt: KnownHostPrompt) async throws {
        let fileURL = try knownHostsFileURL()
        try ensureParentDirectory(for: fileURL)

        let hostKey = hostPattern(host: prompt.host, port: prompt.port)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try? runProcessSync(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-R", hostKey, "-f", fileURL.path]
            )
        }

        let existingLines = try loadKnownHostsLines()
        let mergedLines = existingLines + prompt.scannedLines
        let content = mergedLines.joined(separator: "\n") + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    nonisolated static func defaultKnownHostsFilePath() throws -> String {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("ShellX", isDirectory: true)
            .appendingPathComponent("known_hosts", isDirectory: false)
            .path
    }

    nonisolated static func temporaryKnownHostsFilePath(for prompt: KnownHostPrompt) throws -> String {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("ShellX", isDirectory: true)
            .appendingPathComponent("KnownHosts", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let fileURL = directoryURL.appendingPathComponent("\(prompt.host)-\(prompt.port)-\(prompt.id.uuidString).known_hosts")
        let content = prompt.scannedLines.joined(separator: "\n") + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return fileURL.path
    }

    private func trustedLines(for host: String, port: Int) throws -> [String] {
        let fileURL = try knownHostsFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let key = hostPattern(host: host, port: port)
        let output: String
        do {
            output = try runProcessSync(
                executable: "/usr/bin/ssh-keygen",
                arguments: ["-F", key, "-f", fileURL.path]
            )
        } catch {
            // `ssh-keygen -F` 在无匹配记录时可能返回非 0，这里应视为“未信任”而不是校验失败。
            return []
        }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func loadKnownHostsLines() throws -> [String] {
        let fileURL = try knownHostsFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return content
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    private func knownHostsFileURL() throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("ShellX", isDirectory: true)
            .appendingPathComponent("known_hosts", isDirectory: false)
    }

    private func ensureParentDirectory(for fileURL: URL) throws {
        let parentURL = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }
    }

    private func scanHostKeys(host: String, port: Int) async throws -> [String] {
        let preferredAlgorithms = "ed25519,ecdsa,rsa"
        let output: String
        var failureDetails: [String] = []

        do {
            // 显式拉取常见 host key 算法，避免默认扫描结果缺少当前 ssh 实际协商到的算法。
            output = try await runProcess(
                executable: "/usr/bin/ssh-keyscan",
                arguments: ["-T", "5", "-t", preferredAlgorithms, "-p", "\(port)", host]
            )
        } catch {
            failureDetails.append("指定算法扫描失败：\(Self.scanFailureDetail(from: error))")
            do {
                output = try await runProcess(
                    executable: "/usr/bin/ssh-keyscan",
                    arguments: ["-T", "5", "-p", "\(port)", host]
                )
            } catch {
                failureDetails.append("默认扫描失败：\(Self.scanFailureDetail(from: error))")
                throw KnownHostsError.scanFailed(
                    Self.scanFailureDescription(
                        host: host,
                        port: port,
                        preferredAlgorithms: preferredAlgorithms,
                        failureDetails: failureDetails
                    )
                )
            }
        }

        var seen = Set<String>()
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
    }

    nonisolated static func scanFailureDescription(
        host: String,
        port: Int,
        preferredAlgorithms: String,
        failureDetails: [String]
    ) -> String {
        var lines = [
            "无法通过 ssh-keyscan 获取 \(host):\(port) 的主机指纹。",
            "请确认目标主机在该端口运行 SSH 服务、网络可达且防火墙未在握手阶段主动断开连接。"
        ]
        if !failureDetails.isEmpty {
            lines.append("底层错误：")
            lines.append(contentsOf: failureDetails.map { "- \($0)" })
        }
        lines.append("可先手动执行：ssh-keyscan -T 5 -t \(preferredAlgorithms) -p \(port) \(host)")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func scanFailureDetail(from error: Error) -> String {
        if let knownHostsError = error as? KnownHostsError,
           case .scanFailed(let message) = knownHostsError {
            return message
        }
        return error.localizedDescription
    }

    private func fingerprint(line: String) throws -> String {
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("shellx-known-host-\(UUID().uuidString).pub")
        try (line + "\n").write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: tempURL) }

        let output = try runProcessSync(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-lf", tempURL.path]
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            do {
                continuation.resume(returning: try runProcessSync(executable: executable, arguments: arguments))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runProcessSync(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        guard process.terminationStatus == 0 || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let commandDescription = ([executable] + arguments).joined(separator: " ")
            let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw KnownHostsError.scanFailed(
                message.isEmpty ? "命令执行失败：\(commandDescription)" : "\(message)\n命令：\(commandDescription)"
            )
        }

        return output
    }
}

enum KnownHostsError: LocalizedError {
    case scanFailed(String)

    var errorDescription: String? {
        switch self {
        case .scanFailed(let message):
            return "主机指纹校验失败：\(message)"
        }
    }
}
