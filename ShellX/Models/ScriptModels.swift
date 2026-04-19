import Foundation

struct UserScript: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        content: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ScriptLibrary: Codable, Sendable {
    var scripts: [UserScript]

    static let empty = ScriptLibrary(scripts: [])
}

enum ScriptExecutionStatus: Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed(String)

    var title: String {
        switch self {
        case .pending:
            return "等待中"
        case .running:
            return "执行中"
        case .succeeded:
            return "成功"
        case .failed:
            return "失败"
        }
    }

    var isFinished: Bool {
        switch self {
        case .succeeded, .failed:
            return true
        case .pending, .running:
            return false
        }
    }
}

struct ScriptExecutionResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let sessionName: String
    var status: ScriptExecutionStatus
    var output: String

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        sessionName: String,
        status: ScriptExecutionStatus = .pending,
        output: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.status = status
        self.output = output
    }
}
