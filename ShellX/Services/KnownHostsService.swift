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
        let scannedLines = try await scanHostKeys(host: host, port: port)
        guard !scannedLines.isEmpty else {
            throw KnownHostsError.scanFailed("未获取到主机公钥")
        }

        let newFingerprints = try scannedLines.map(fingerprint)
        let storedLines = try trustedLines(for: host, port: port)
        let existingFingerprints = try storedLines.map(fingerprint)

        if storedLines.isEmpty {
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

        if existingSet != newSet {
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

    private func trustedLines(for host: String, port: Int) throws -> [String] {
        let fileURL = try knownHostsFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let key = hostPattern(host: host, port: port)
        let output = try runProcessSync(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-F", key, "-f", fileURL.path]
        )
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

        do {
            // 显式拉取常见 host key 算法，避免默认扫描结果缺少当前 ssh 实际协商到的算法。
            output = try await runProcess(
                executable: "/usr/bin/ssh-keyscan",
                arguments: ["-T", "5", "-t", preferredAlgorithms, "-p", "\(port)", host]
            )
        } catch {
            output = try await runProcess(
                executable: "/usr/bin/ssh-keyscan",
                arguments: ["-T", "5", "-p", "\(port)", host]
            )
        }

        var seen = Set<String>()
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
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
            throw KnownHostsError.scanFailed(errorOutput.isEmpty ? "执行失败" : errorOutput)
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
