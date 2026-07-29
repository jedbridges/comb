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

    /// Whether this build can use the Keychain at all.
    ///
    /// An app built without code signing has no keychain-access-group
    /// entitlement, and every write fails with errSecMissingEntitlement
    /// (-34018). That is the state on CI, which builds with
    /// CODE_SIGNING_ALLOWED=NO because it has no certificates. The check below
    /// is about Comb's logic, not about the Keychain existing, so it is skipped
    /// there rather than failing for a reason that says nothing about the code.
    ///
    /// Probed rather than keyed off a CI environment variable: "skip when the
    /// entitlement is missing" stays true wherever it runs, while "skip on CI"
    /// would also hide a real failure the day CI gains signing.
    static let keychainIsEntitled: Bool = {
        let host = "entitlement-probe-\(UUID().uuidString).invalid"
        defer { try? KeychainStore.delete(host: host) }
        do {
            try KeychainStore.save(try PrivateKey(), host: host)
            return true
        } catch KeychainStore.Failure.unexpectedStatus(errSecMissingEntitlement) {
            return false
        } catch {
            // Anything else is a real problem and should surface as a failure
            // in the test itself, not be swallowed here.
            return true
        }
    }()

    @Test(
        "a host is known to the Keychain only once a key is saved for it",
        .enabled(if: AppTargetTests.keychainIsEntitled, "needs a signed build for Keychain access")
    )
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
