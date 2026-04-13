import Foundation

actor AppStorageRepository {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func loadWorkspace() async throws -> SessionWorkspace {
        let fileURL = try workspaceFileURL()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SampleData.workspace
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(SessionWorkspace.self, from: data)
    }

    func saveWorkspace(_ workspace: SessionWorkspace) async throws {
        let fileURL = try workspaceFileURL()
        try ensureParentDirectory(for: fileURL)
        let data = try encoder.encode(workspace)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func workspaceFileURL() throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL
            .appendingPathComponent("ShellX", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }

    private func ensureParentDirectory(for fileURL: URL) throws {
        let parentURL = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentURL.path) {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        }
    }
}

enum SampleData {
    static var workspace: SessionWorkspace {
        let production = SessionFolder(name: "生产环境")
        let staging = SessionFolder(name: "预发环境")
        let projectA = SessionFolder(parentID: production.id, name: "项目 A")
        let projectB = SessionFolder(parentID: staging.id, name: "项目 B")

        let sessions = [
            SSHSessionProfile(
                folderID: projectA.id,
                name: "prod-web-01",
                host: "10.0.0.11",
                username: "deploy",
                authMethod: .sshAgent,
                tags: ["生产环境", "Web", "节点"]
            ),
            SSHSessionProfile(
                folderID: projectB.id,
                name: "staging-api-01",
                host: "10.0.1.25",
                username: "ubuntu",
                authMethod: .privateKey,
                privateKeyPath: "~/.ssh/id_ed25519",
                startupCommand: "cd /srv/app",
                tags: ["预发环境", "API", "机器"]
            )
        ]

        return SessionWorkspace(
            folders: [production, staging, projectA, projectB],
            sessions: sessions
        )
    }
}
