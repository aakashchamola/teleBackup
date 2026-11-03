import Foundation
import Security

/// Bot token and similar secrets. They live only in the iPhone Keychain, never in the database or the logs.
enum Keychain {
    private static let service = "com.aakashchamola.telebackup"
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func put(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let v = value else { return }
        var add = base; add[kSecValueData as String] = v.data(using: .utf8)!
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock   // background tasks run while the phone is locked
        SecItemAdd(add as CFDictionary, nil)
    }
}
