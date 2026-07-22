import CombCore
import Foundation
import Security

/// Custody of account keys, one per community host.
///
/// Non-synchronizable and this-device-only by deliberate choice: the README
/// promises keys stay on the device, and iCloud Keychain sync would quietly
/// break that promise. Backup, when it arrives, will be an explicit opt-in
/// with honest copy, not a default.
enum KeychainStore {
    private static let service = "dev.jedbridges.comb.identity"

    enum Failure: Error {
        case unexpectedStatus(OSStatus)
    }

    /// Stores a key for a community, replacing any previous one.
    static func save(_ key: PrivateKey, host: String) throws {
        // Delete-then-add rather than update: simpler, and the value is tiny.
        try? delete(host: host)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecValueData as String: key.data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
    }

    /// The key for a community, if this device holds one.
    static func load(host: String) throws -> PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try? PrivateKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    static func delete(host: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }
}
