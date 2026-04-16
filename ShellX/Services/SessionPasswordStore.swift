import Foundation
import Security

final class SessionPasswordStore {
    private let service = "com.shellx.session-password"
    private static var cachedPasswords: [UUID: String] = [:]
    private static var diagnosticEntries: [String] = []
    private static let diagnosticFormatter = ISO8601DateFormatter()

    func savePassword(_ password: String, for sessionID: UUID) throws {
        Self.recordDiagnostic("savePassword.begin", sessionID: sessionID)
        guard let data = password.data(using: .utf8) else {
            Self.recordDiagnostic("savePassword.invalidEncoding", sessionID: sessionID)
            throw PasswordStoreError.invalidEncoding
        }

        let account = sessionID.uuidString
        let updateStatus = SecItemUpdate(
            baseQuery(for: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            // 已有标准登录 Keychain 条目时只更新值，避免 delete + add 触发两次系统授权。
            Self.cachedPasswords[sessionID] = password
            Self.recordDiagnostic("savePassword.update.success", sessionID: sessionID)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            Self.recordDiagnostic("savePassword.update.failure.\(updateStatus)", sessionID: sessionID)
            throw PasswordStoreError.keychain(updateStatus)
        }

        var addQuery = baseQuery(for: account)
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.recordDiagnostic("savePassword.add.failure.\(addStatus)", sessionID: sessionID)
            throw PasswordStoreError.keychain(addStatus)
        }
        // 进程内缓存一份，避免刚保存后立即连接时再次触发 Keychain 授权。
        Self.cachedPasswords[sessionID] = password
        Self.recordDiagnostic("savePassword.add.success", sessionID: sessionID)
    }

    func loadPassword(for sessionID: UUID) throws -> String? {
        if let cachedPassword = Self.cachedPasswords[sessionID] {
            Self.recordDiagnostic("loadPassword.cacheHit", sessionID: sessionID)
            return cachedPassword
        }

        Self.recordDiagnostic("loadPassword.keychain.begin", sessionID: sessionID)
        var query = baseQuery(for: sessionID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            Self.recordDiagnostic("loadPassword.keychain.notFound", sessionID: sessionID)
            return try migrateLegacyPasswordIfNeeded(for: sessionID)
        }
        guard status == errSecSuccess else {
            Self.recordDiagnostic("loadPassword.keychain.failure.\(status)", sessionID: sessionID)
            throw PasswordStoreError.keychain(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            Self.recordDiagnostic("loadPassword.invalidEncoding", sessionID: sessionID)
            throw PasswordStoreError.invalidEncoding
        }
        // 已经成功通过一次系统授权后，后续同进程内读取直接复用内存缓存。
        Self.cachedPasswords[sessionID] = password
        Self.recordDiagnostic("loadPassword.keychain.success", sessionID: sessionID)
        return password
    }

    func cachedPassword(for sessionID: UUID) -> String? {
        Self.cachedPasswords[sessionID]
    }

    func cachePassword(_ password: String, for sessionID: UUID) {
        Self.cachedPasswords[sessionID] = password
        Self.recordDiagnostic("cachePassword.memoryOnly", sessionID: sessionID)
    }

    func hasPassword(for sessionID: UUID) -> Bool {
        (try? loadPassword(for: sessionID)) != nil
    }

    func deletePassword(for sessionID: UUID) throws {
        Self.cachedPasswords.removeValue(forKey: sessionID)
        Self.recordDiagnostic("deletePassword.begin", sessionID: sessionID)
        let status = SecItemDelete(baseQuery(for: sessionID.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Self.recordDiagnostic("deletePassword.failure.\(status)", sessionID: sessionID)
            throw PasswordStoreError.keychain(status)
        }
        Self.recordDiagnostic("deletePassword.success.\(status)", sessionID: sessionID)
    }

    static func debugSnapshot() -> String {
        diagnosticEntries.joined(separator: "\n")
    }

    static func clearDebugSnapshot() {
        diagnosticEntries.removeAll(keepingCapacity: true)
    }

    private static func recordDiagnostic(_ event: String, sessionID: UUID) {
        let timestamp = diagnosticFormatter.string(from: Date())
        diagnosticEntries.append("[SessionPasswordStore] \(timestamp) session=\(sessionID.uuidString) \(event)")
        if diagnosticEntries.count > 200 {
            diagnosticEntries.removeFirst(diagnosticEntries.count - 200)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // 这里刻意不再强制启用 Data Protection Keychain。
            // ShellX 是桌面端 macOS 应用，目标行为是首次保存后，
            // 后续重新打开应用仍能直接从标准登录 Keychain 读取，
            // 而不是每次新进程首次访问都再次触发系统授权。
        ]
    }

    private func legacyBaseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }

    private func migrateLegacyPasswordIfNeeded(for sessionID: UUID) throws -> String? {
        Self.recordDiagnostic("loadPassword.legacy.begin", sessionID: sessionID)
        var query = legacyBaseQuery(for: sessionID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            Self.recordDiagnostic("loadPassword.legacy.notFound", sessionID: sessionID)
            return nil
        }
        guard status == errSecSuccess else {
            Self.recordDiagnostic("loadPassword.legacy.failure.\(status)", sessionID: sessionID)
            throw PasswordStoreError.keychain(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            Self.recordDiagnostic("loadPassword.legacy.invalidEncoding", sessionID: sessionID)
            throw PasswordStoreError.invalidEncoding
        }

        try savePassword(password, for: sessionID)
        Self.recordDiagnostic("loadPassword.legacy.migrated", sessionID: sessionID)
        return password
    }
}

enum PasswordStoreError: LocalizedError {
    case invalidEncoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "密码编码失败"
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误：\(status)"
        }
    }
}
