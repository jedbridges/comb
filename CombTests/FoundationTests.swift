import CombCore
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
}
