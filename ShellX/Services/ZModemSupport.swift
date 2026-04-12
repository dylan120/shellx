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

enum ZModemTransferState: Equatable {
    case idle
    case preparing(ZModemTransferDirection)
    case transferring(ZModemTransferDirection)
    case completed(String)
    case failed(String)

    var bannerText: String? {
        switch self {
        case .idle:
            return nil
        case .preparing(let direction):
            return "\(direction.displayName)，等待选择文件..."
        case .transferring(let direction):
            return "\(direction.displayName)，请勿关闭当前终端"
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
    private let downloadPattern = #"\*\*B0{14,}[0-9A-Fa-f]*"#
    private(set) var buffer = ""

    mutating func consume(_ data: Data) -> ZModemTrigger? {
        let chunk = Self.normalizedASCII(from: data)
        guard !chunk.isEmpty else { return nil }
        buffer.append(chunk)
        if buffer.count > maxBufferLength {
            buffer = String(buffer.suffix(maxBufferLength))
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
