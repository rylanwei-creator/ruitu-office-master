import Foundation
import Security

protocol RitoCredentialStore: Sendable {
    func read(_ account: String) throws -> String?
    func save(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

struct RitoKeychainError: LocalizedError, Equatable {
    let status: OSStatus
    var errorDescription: String? {
        switch status {
        case errSecUserCanceled:
            "钥匙串授权未完成（-128），尚未发送 AI 请求。请点击重试，在 macOS 授权窗口允许访问；也可在 AI 设置重新保存密钥"
        case errSecAuthFailed:
            "钥匙串未授权访问。请在 AI 设置重新保存密钥，并完成 macOS 授权"
        case errSecInteractionNotAllowed, errSecNotAvailable:
            "钥匙串当前不可访问，请解锁登录钥匙串后重试；普通工具仍可使用"
        default:
            "无法访问 macOS 钥匙串（\(status)）。请在 AI 设置检查密钥并重试"
        }
    }
}

struct RitoKeychain: RitoCredentialStore {
    var service = "com.ruitu.officemaster.rito-credentials"
    func read(_ account: String) throws -> String? {
        var query = base(account); query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw keychainError(errSecDecode)
        }
        return value
    }
    func save(_ value: String, account: String) throws {
        guard !value.isEmpty, value.count <= 4096, !value.contains("\n"), !value.contains("\r") else {
            throw NSError(domain: "RitoKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "密钥不能为空或包含换行"])
        }
        let query = base(account), data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query; item[kSecValueData] = data; item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw keychainError(status) }
        } else if update != errSecSuccess { throw keychainError(update) }
    }
    func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
    private func keychainError(_ status: OSStatus) -> RitoKeychainError { .init(status: status) }
}
