import Foundation
import Security

final class SessionPasswordStore {
    private let service = "com.shellx.session-password"
    private var cachedPasswords: [UUID: String] = [:]

    func savePassword(_ password: String, for sessionID: UUID) throws {
        guard let data = password.data(using: .utf8) else {
            throw PasswordStoreError.invalidEncoding
        }

        let account = sessionID.uuidString
        let query = baseQuery(for: account)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess {
            // 更新已有条目成功后，同步刷新进程内缓存，避免连接时再次触发授权。
            cachedPasswords[sessionID] = password
            return
        }

        guard status == errSecItemNotFound else {
            throw PasswordStoreError.keychain(status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PasswordStoreError.keychain(addStatus)
        }
        // 进程内缓存一份，避免刚保存后立即连接时再次触发 Keychain 授权。
        cachedPasswords[sessionID] = password
    }

    func loadPassword(for sessionID: UUID) throws -> String? {
        if let cachedPassword = cachedPasswords[sessionID] {
            return cachedPassword
        }

        var query = baseQuery(for: sessionID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw PasswordStoreError.keychain(status)
        }
        guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw PasswordStoreError.invalidEncoding
        }
        // 已经成功通过一次系统授权后，后续同进程内读取直接复用内存缓存。
        cachedPasswords[sessionID] = password
        return password
    }

    func hasPassword(for sessionID: UUID) -> Bool {
        (try? loadPassword(for: sessionID)) != nil
    }

    func deletePassword(for sessionID: UUID) throws {
        cachedPasswords.removeValue(forKey: sessionID)
        let status = SecItemDelete(baseQuery(for: sessionID.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.keychain(status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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
