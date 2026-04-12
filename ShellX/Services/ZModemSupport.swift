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
    private(set) var buffer = ""

    mutating func consume(_ data: Data) -> ZModemTrigger? {
        let chunk = String(decoding: data, as: UTF8.self)
        buffer.append(chunk)
        if buffer.count > maxBufferLength {
            buffer = String(buffer.suffix(maxBufferLength))
        }

        if buffer.range(of: #"rz waiting to receive\.\*\*B0100"#, options: .regularExpression) != nil {
            buffer.removeAll(keepingCapacity: true)
            return .uploadRequest
        }

        if buffer.contains("**B00000000000000") {
            buffer.removeAll(keepingCapacity: true)
            return .downloadRequest
        }

        return nil
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
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

