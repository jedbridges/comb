import CombCore
import CombNet
import Foundation
import Security

/// Custody of a wallet connection, one per community host.
///
/// A separate service from `KeychainStore`, not a second account on the same
/// one, and the reason is revocation. "Forget my wallet" and "forget my
/// identity" are different acts with different consequences, and keeping them in
/// one bag means either can be deleted by a query written for the other. Two
/// services are separately enumerable, so removing every wallet this app knows
/// cannot touch a single account key.
///
/// The secret is the credential. It signs every request and derives the
/// conversation key, so it lives here and never in `UserDefaults`, where the
/// rest of the connection sits.
///
/// Same protection as an identity key: this device only, never synchronised.
/// A spend credential in iCloud Keychain would be a spend credential on every
/// device the reader owns and on any they later add, which is not what pasting
/// a URI into one phone asks for.
/// `@MainActor` because the non-secret half lives in `WalletSettings`, which
/// follows the house convention for settings. The session never reads this: a
/// connection is handed to it, so nothing below the UI reaches into defaults.
@MainActor
enum WalletStore {
    private static let service = "dev.jedbridges.comb.wallet"

    enum Failure: Error {
        case unexpectedStatus(OSStatus)
    }

    /// Remembers a connection for a community.
    ///
    /// The relay and wallet pubkey go to `WalletSettings`, which is readable
    /// without unlocking anything. Only the secret is in the Keychain, because
    /// only the secret can spend.
    static func save(_ connection: NWC.Connection, host: String) throws {
        try? forget(host: host)
        WalletSettings.remember(connection, host: host)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecValueData as String: connection.secret.data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
    }

    /// The connection for a community, rebuilt from the secret plus the parts
    /// kept in settings.
    ///
    /// Nil when any piece is missing, which is deliberate: a half-remembered
    /// connection is not one to try paying with, and the reader should be asked
    /// to connect again rather than shown a failure from a relay Comb guessed at.
    static func load(host: String) -> NWC.Connection? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = try? PrivateKey(data: data)
        else { return nil }

        guard let walletHex = WalletSettings.walletPubkey(host: host),
              let walletPubkey = PublicKey(hex: walletHex),
              let relay = WalletSettings.relay(host: host)
        else { return nil }

        return NWC.Connection(
            walletPubkey: walletPubkey,
            relays: [relay],
            secret: secret,
            lightningAddress: WalletSettings.lightningAddress(host: host)
        )
    }

    static func exists(host: String) -> Bool {
        load(host: host) != nil
    }

    /// Removes the credential and everything describing it.
    ///
    /// Both halves, always. Leaving the relay and wallet pubkey behind after
    /// deleting the secret would leave the UI able to claim a wallet is
    /// connected when nothing can be paid with it.
    static func forget(host: String) throws {
        WalletSettings.clear(host: host)

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

/// The non-secret half of a wallet connection.
///
/// Follows `SyncSettings`: a `@MainActor enum` of static accessors over
/// `UserDefaults`, keyed by community host the way `NotificationSettings.isMuted`
/// is. None of this is sensitive on its own. A relay URL and a wallet's public
/// key say which service the reader uses, which is worth keeping off a screen
/// but is not worth a Keychain round trip on every render.
@MainActor
enum WalletSettings {
    private static let walletPrefix = "comb.wallet.pubkey."
    private static let relayPrefix = "comb.wallet.relay."
    private static let addressPrefix = "comb.wallet.lud16."

    static func walletPubkey(host: String) -> String? {
        UserDefaults.standard.string(forKey: walletPrefix + host)
    }

    static func relay(host: String) -> URL? {
        UserDefaults.standard.string(forKey: relayPrefix + host).flatMap(URL.init(string:))
    }

    static func lightningAddress(host: String) -> String? {
        UserDefaults.standard.string(forKey: addressPrefix + host)
    }

    static func remember(_ connection: NWC.Connection, host: String) {
        let defaults = UserDefaults.standard
        defaults.set(connection.walletPubkey.hex, forKey: walletPrefix + host)
        defaults.set(connection.relays.first?.absoluteString, forKey: relayPrefix + host)
        defaults.set(connection.lightningAddress, forKey: addressPrefix + host)
    }

    static func clear(host: String) {
        let defaults = UserDefaults.standard
        for prefix in [walletPrefix, relayPrefix, addressPrefix] {
            defaults.removeObject(forKey: prefix + host)
        }
    }
}
