import Foundation

enum ZModemTransferDirection: Equatable {
    case uploadToRemote
    case downloadFromRemote

    var displayName: String {
        switch self {
        case .uploadToRemote:
            return "上传中"
        case .downloadFromRemote:
            return "下载中"
        }
    }
}

enum SFTPTransferDirection: Equatable {
    case upload
    case download

    var displayName: String {
        switch self {
        case .upload:
            return "SFTP 上传中"
        case .download:
            return "SFTP 下载中"
        }
    }
}

struct ZModemTransferProgress: Equatable {
    let direction: ZModemTransferDirection
    var currentFileName: String?
    var completedFiles: Int
    var totalFiles: Int?
    var percent: Int?
    var byteSummary: String?
    var speed: String?
    var eta: String?

    init(
        direction: ZModemTransferDirection,
        currentFileName: String? = nil,
        completedFiles: Int = 0,
        totalFiles: Int? = nil,
        percent: Int? = nil,
        byteSummary: String? = nil,
        speed: String? = nil,
        eta: String? = nil
    ) {
        self.direction = direction
        self.currentFileName = currentFileName
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.percent = percent
        self.byteSummary = byteSummary
        self.speed = speed
        self.eta = eta
    }

    var bannerText: String {
        var parts: [String] = []
        var headline = direction.displayName
        if let totalFiles, totalFiles > 1 {
            let currentIndex = min(completedFiles + 1, totalFiles)
            headline += "（\(currentIndex)/\(totalFiles)）"
        }
        parts.append(headline)

        if let currentFileName, !currentFileName.isEmpty {
            parts.append(currentFileName)
        }
        if let percent {
            parts.append("\(percent)%")
        }
        if let byteSummary, !byteSummary.isEmpty {
            parts.append(byteSummary)
        }
        if let speed, !speed.isEmpty {
            parts.append(speed)
        }
        if let eta, !eta.isEmpty {
            parts.append("剩余 \(eta)")
        }

        return parts.joined(separator: " · ")
    }
}

struct SFTPTransferProgress: Equatable {
    let direction: SFTPTransferDirection
    var currentFileName: String?
    var completedFiles: Int
    var totalFiles: Int?
    var percent: Int?
    var byteSummary: String?
    var speed: String?
    var eta: String?

    init(
        direction: SFTPTransferDirection,
        currentFileName: String? = nil,
        completedFiles: Int = 0,
        totalFiles: Int? = nil,
        percent: Int? = nil,
        byteSummary: String? = nil,
        speed: String? = nil,
        eta: String? = nil
    ) {
        self.direction = direction
        self.currentFileName = currentFileName
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.percent = percent
        self.byteSummary = byteSummary
        self.speed = speed
        self.eta = eta
    }

    var bannerText: String {
        var parts: [String] = [direction.displayName]

        if let totalFiles, totalFiles > 1 {
            let currentIndex = min(completedFiles + 1, totalFiles)
            parts[0] += "（\(currentIndex)/\(totalFiles)）"
        }

        if let currentFileName, !currentFileName.isEmpty {
            parts.append(currentFileName)
        }
        if let percent {
            parts.append("\(percent)%")
        }
        if let byteSummary, !byteSummary.isEmpty {
            parts.append(byteSummary)
        }
        if let speed, !speed.isEmpty {
            parts.append(speed)
        }
        if let eta, !eta.isEmpty {
            parts.append("剩余 \(eta)")
        }

        return parts.joined(separator: " · ")
    }
}

enum ZModemTransferState: Equatable {
    case idle
    case preparing(ZModemTransferDirection)
    case transferring(ZModemTransferProgress)
    case sftpTransferring(SFTPTransferProgress)
    case completed(String)
    case failed(String)

    var bannerText: String? {
        switch self {
        case .idle:
            return nil
        case .preparing(let direction):
            return "\(direction.displayName)，等待选择文件..."
        case .transferring(let progress):
            return progress.bannerText
        case .sftpTransferring(let progress):
            return progress.bannerText
        case .completed(let message), .failed(let message):
            return message
        }
    }
}

enum ZModemTrigger: Equatable {
    case uploadRequest
    case downloadRequest
}

struct ZModemTriggerDetector {
    private let maxBufferLength = 4096
    private let uploadPromptPattern = #"rz waiting to receive\.\*\*B01[0-9A-Fa-f]{8,}"#
    private let uploadHandshakePattern = #"\*\*B01[0-9A-Fa-f]{8,}"#
    private let genericHandshakePattern = #"\*\*B0[0-9A-Fa-f]{8,}"#
    private let downloadPattern = #"\*\*B0[0-9A-Fa-f]{8,}"#
    private(set) var buffer = ""

    mutating func consume(_ data: Data, preferredDirection: ZModemTransferDirection? = nil) -> ZModemTrigger? {
        let chunk = Self.normalizedASCII(from: data)
        guard !chunk.isEmpty else { return nil }
        buffer.append(chunk)
        if buffer.count > maxBufferLength {
            buffer = String(buffer.suffix(maxBufferLength))
        }

        if let preferredDirection,
           buffer.range(of: genericHandshakePattern, options: .regularExpression) != nil {
            buffer.removeAll(keepingCapacity: true)
            switch preferredDirection {
            case .uploadToRemote:
                return .uploadRequest
            case .downloadFromRemote:
                return .downloadRequest
            }
        }

        // 终端回显经常会把 "rz waiting to receive." 文本切碎，只保留真实的 ZMODEM 起始帧。
        // 因此上传检测优先识别协议握手本身，而不是依赖完整提示文案连续出现。
        if buffer.range(of: uploadPromptPattern, options: .regularExpression) != nil ||
            buffer.range(of: uploadHandshakePattern, options: .regularExpression) != nil {
            buffer.removeAll(keepingCapacity: true)
            return .uploadRequest
        }

        if buffer.range(of: downloadPattern, options: .regularExpression) != nil {
            buffer.removeAll(keepingCapacity: true)
            return .downloadRequest
        }

        return nil
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private static func normalizedASCII(from data: Data) -> String {
        let bytes = data.filter { byte in
            switch byte {
            case 0x20...0x7E:
                return true
            case 0x0A, 0x0D, 0x09:
                return true
            default:
                return false
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum ZModemHelperLocator {
    static func path(named command: String) -> String? {
        let candidates = [
            "/bin/\(command)",
            "/usr/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}

enum ZModemControlBytes {
    static let cancel = Data([0x18, 0x18, 0x18, 0x18, 0x18])
}

struct ZModemProgressParser {
    private var textBuffer = ""
    private(set) var progress: ZModemTransferProgress
    private var knownFiles: [String] = []

    init(direction: ZModemTransferDirection, totalFiles: Int? = nil) {
        progress = ZModemTransferProgress(direction: direction, totalFiles: totalFiles)
    }

    mutating func consume(_ data: Data) -> ZModemTransferProgress? {
        // lrzsz 常把进度写到 stderr，并频繁用 CR 覆盖同一行；这里保留一小段滑动窗口做增量解析。
        let chunk = Self.normalizedText(from: data)
        guard !chunk.isEmpty else { return nil }

        textBuffer.append(chunk)
        if textBuffer.count > 4096 {
            textBuffer = String(textBuffer.suffix(4096))
        }

        let segments = textBuffer
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map(String.init)
        guard !segments.isEmpty else { return nil }

        var didUpdate = false
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if applyFilenameIfNeeded(from: trimmed) {
                didUpdate = true
            }
            if applyMetricsIfNeeded(from: trimmed) {
                didUpdate = true
            }
        }

        return didUpdate ? progress : nil
    }

    mutating func markCompleted() {
        if let currentFileName = progress.currentFileName, !currentFileName.isEmpty {
            registerFileIfNeeded(currentFileName)
        }
        progress.completedFiles = max(progress.completedFiles, knownFiles.count)
        progress.percent = 100
        progress.eta = nil
    }

    private mutating func applyFilenameIfNeeded(from line: String) -> Bool {
        // 不同平台/版本的 lrzsz 文案略有差异，这里只抓稳定的 sending/receiving/file/path 前缀。
        let patterns = [
            #"(?i)\b(?:sending|receiving)\s*:\s*(.+)$"#,
            #"(?i)\b(?:sending|receiving)\s+(.+)$"#,
            #"(?i)\b(?:file|path)\s*:\s*(.+)$"#
        ]

        for pattern in patterns {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let fileName = match
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !fileName.isEmpty else { continue }

            if progress.currentFileName != fileName {
                if let current = progress.currentFileName, !current.isEmpty {
                    registerFileIfNeeded(current)
                }
                progress.currentFileName = fileName
                progress.percent = nil
                progress.byteSummary = nil
                progress.speed = nil
                progress.eta = nil
            }
            registerFileIfNeeded(fileName)
            progress.completedFiles = max(knownFiles.count - 1, 0)
            return true
        }
        return false
    }

    private mutating func applyMetricsIfNeeded(from line: String) -> Bool {
        var didUpdate = false

        if let percentText = line.firstMatch(of: #"(\d{1,3})%"#),
           let percentValue = Int(percentText) {
            progress.percent = min(percentValue, 100)
            didUpdate = true
        }

        if let speed = line.firstMatch(of: #"(?i)\b(\d+(?:\.\d+)?\s*(?:[KMG]?B|bytes?)(?:/s|ps))\b"#) {
            progress.speed = speed
            didUpdate = true
        }

        if let eta = line.firstMatch(of: #"(?i)\b(?:eta|time left)\s*[: ]\s*([0-9:]+)\b"#) {
            progress.eta = eta
            didUpdate = true
        } else if let eta = line.firstMatch(of: #"(?i)\b([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\s*ETA\b"#) {
            progress.eta = eta
            didUpdate = true
        }

        if let byteSummary = line.firstMatch(of: #"(\d+(?:\.\d+)?\s*(?:[KMG]?B|bytes?)(?:\s*/\s*\d+(?:\.\d+)?\s*(?:[KMG]?B|bytes?))?)"#) {
            progress.byteSummary = byteSummary.replacingOccurrences(of: "bytes", with: "B")
            didUpdate = true
        }

        return didUpdate
    }

    private mutating func registerFileIfNeeded(_ fileName: String) {
        guard !knownFiles.contains(fileName) else { return }
        knownFiles.append(fileName)
        if let totalFiles = progress.totalFiles {
            progress.totalFiles = max(totalFiles, knownFiles.count)
        } else {
            progress.totalFiles = knownFiles.count
        }
    }

    private static func normalizedText(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .filter { character in
                character == "\r" || character == "\n" || character == "\t" || character.isASCII
            }
    }
}

extension String {
    fileprivate func firstMatch(of pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: self) else {
            return nil
        }
        return String(self[valueRange])
    }
}
