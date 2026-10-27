import Foundation
import Security

public protocol SecretStore: AnyObject {
    func get(_ account: String) -> String?
    func set(_ value: String, for account: String) throws
}

/// API keys live in the macOS Keychain, never on disk.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.hypernote2.app") {
        self.service = service
    }

    public func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw HypernoteError.message("Keychain error \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw HypernoteError.message("Keychain error \(status)")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func get(_ account: String) -> String? { values[account] }
    public func set(_ value: String, for account: String) throws { values[account] = value }
}
