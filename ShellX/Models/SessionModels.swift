import Foundation

enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable {
    case sshAgent = "agent"
    case privateKey = "privateKey"
    case password = "password"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sshAgent:
            return "SSH Agent"
        case .privateKey:
            return "私钥文件"
        case .password:
            return "账号密码"
        }
    }
}

struct SessionFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var parentID: UUID?
    var name: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SSHSessionProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var folderID: UUID?
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: SSHAuthMethod
    var privateKeyPath: String
    var passwordStoredInKeychain: Bool
    var useKeychainForPrivateKey: Bool
    var startupCommand: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        folderID: UUID? = nil,
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: SSHAuthMethod = .sshAgent,
        privateKeyPath: String = "",
        passwordStoredInKeychain: Bool = false,
        useKeychainForPrivateKey: Bool = false,
        startupCommand: String = "",
        tags: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
        self.passwordStoredInKeychain = passwordStoredInKeychain
        self.useKeychainForPrivateKey = useKeychainForPrivateKey
        self.startupCommand = startupCommand
        self.tags = Self.normalizeTags(tags)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case folderID
        case name
        case host
        case port
        case username
        case authMethod
        case privateKeyPath
        case passwordStoredInKeychain
        case useKeychainForPrivateKey
        case startupCommand
        case tags
        case notes
        case createdAt
        case updatedAt
        case lastConnectedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = try container.decodeIfPresent(SSHAuthMethod.self, forKey: .authMethod) ?? .sshAgent
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
        passwordStoredInKeychain = try container.decodeIfPresent(Bool.self, forKey: .passwordStoredInKeychain) ?? false
        useKeychainForPrivateKey = try container.decodeIfPresent(Bool.self, forKey: .useKeychainForPrivateKey) ?? false
        startupCommand = try container.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
        let decodedTags = try container.decodeIfPresent([String].self, forKey: .tags)
        let legacyNotes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        if let decodedTags {
            tags = Self.normalizeTags(decodedTags)
        } else if !legacyNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // 兼容旧版本 sessions.json，将历史“备注”整体迁移为单个标签，避免语义被拆散。
            tags = [legacyNotes.trimmingCharacters(in: .whitespacesAndNewlines)]
        } else {
            tags = []
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(privateKeyPath, forKey: .privateKeyPath)
        try container.encode(passwordStoredInKeychain, forKey: .passwordStoredInKeychain)
        try container.encode(useKeychainForPrivateKey, forKey: .useKeychainForPrivateKey)
        try container.encode(startupCommand, forKey: .startupCommand)
        try container.encode(Self.normalizeTags(tags), forKey: .tags)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
    }

    var destination: String {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUser.isEmpty ? host : "\(trimmedUser)@\(host)"
    }

    var isValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasHost = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validPort = (1...65535).contains(port)
        let validPrivateKey: Bool

        switch authMethod {
        case .sshAgent:
            validPrivateKey = true
        case .privateKey:
            validPrivateKey = !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password:
            validPrivateKey = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return hasName && hasHost && validPort && validPrivateKey
    }

    private static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

struct SessionWorkspace: Codable {
    var folders: [SessionFolder]
    var sessions: [SSHSessionProfile]

    static let empty = SessionWorkspace(folders: [], sessions: [])
}

struct SessionFolderNode: Identifiable, Hashable {
    let folder: SessionFolder
    var children: [SessionFolderNode]

    var id: UUID { folder.id }
}
