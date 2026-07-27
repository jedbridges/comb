@testable import Comb
import CombCore
import Foundation
import Testing

/// App-target tests. Deliberately thin: anything testable without a simulator
/// belongs in a package's own test suite, where it runs in milliseconds.
/// This target exists to catch problems that only appear once linked into the
/// app, and later to host UI-level tests.
@Suite("App target")
struct AppTargetTests {
    @Test("CombCore is linked and signing works inside the app bundle")
    func combCoreLinks() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "linked",
            with: key
        )
        #expect(event.isValid)
    }

    @Test("a host is known to the Keychain only once a key is saved for it")
    func keychainExistence() throws {
        // The join screen asks this to decide whether it is about to mint an
        // account, and says so only when it is. A query that answered wrongly
        // would either hide the disclosure from a first-time reader or promise
        // a rejoin an account it is not making.
        let host = "exists-test-\(UUID().uuidString).invalid"
        defer { try? KeychainStore.delete(host: host) }

        #expect(!KeychainStore.exists(host: host))
        try KeychainStore.save(try PrivateKey(), host: host)
        #expect(KeychainStore.exists(host: host))
        try KeychainStore.delete(host: host)
        #expect(!KeychainStore.exists(host: host))
    }
}
