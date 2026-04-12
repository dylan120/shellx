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
    var notes: String
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
        notes: String = "",
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
        self.notes = notes
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
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
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
