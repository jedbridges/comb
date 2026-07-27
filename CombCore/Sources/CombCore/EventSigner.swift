import Foundation

/// Anything that can produce signed events on behalf of an identity.
///
/// The app's real signer reads its key from the Keychain, which can block and can
/// fail, so the requirements are `async throws` even though the in-memory
/// implementation needs neither. Code that signs should depend on this protocol
/// rather than on `PrivateKey`, so a secret never has to be passed around to
/// reach the place where signing happens.
public protocol EventSigner: Sendable {
    func publicKey() async throws -> PublicKey

    func sign(
        kind: EventKind,
        content: String,
        tags: [[String]],
        createdAt: Date
    ) async throws -> NostrEvent

    /// NIP-44 encrypts to this identity's own key, for state a device publishes
    /// for its other devices to read.
    ///
    /// On the signer rather than reached through an exposed `PrivateKey`, for
    /// the same reason signing is: the secret never has to travel to the place
    /// that needs the result. Encrypting to yourself is an ordinary NIP-44
    /// conversation where both parties are the same key.
    func encryptToSelf(_ plaintext: String) async throws -> String
    func decryptFromSelf(_ payload: String) async throws -> String
}

public extension EventSigner {
    /// Signs at the current time, which is what nearly every call site wants.
    func sign(
        kind: EventKind,
        content: String,
        tags: [[String]] = []
    ) async throws -> NostrEvent {
        try await sign(kind: kind, content: content, tags: tags, createdAt: Date())
    }
}

/// A signer holding its key in memory.
///
/// Intended for tests and for the brief window during onboarding between
/// generating a key and committing it to the Keychain. Long-lived use in the app
/// should go through the Keychain-backed signer instead.
public struct InMemorySigner: EventSigner {
    private let key: PrivateKey

    public init(_ key: PrivateKey) {
        self.key = key
    }

    /// Generates a fresh identity.
    public init() throws {
        self.key = try PrivateKey()
    }

    public func publicKey() async throws -> PublicKey {
        key.publicKey
    }

    public func sign(
        kind: EventKind,
        content: String,
        tags: [[String]],
        createdAt: Date
    ) async throws -> NostrEvent {
        guard !kind.isRelaySigned else {
            throw SigningError.relaySignedKind(kind)
        }
        return try NostrEvent.signed(
            kind: kind,
            content: content,
            tags: tags,
            createdAt: createdAt,
            with: key
        )
    }

    public func encryptToSelf(_ plaintext: String) async throws -> String {
        try NIP44.encrypt(plaintext, conversationKey: selfConversationKey())
    }

    public func decryptFromSelf(_ payload: String) async throws -> String {
        try NIP44.decrypt(payload, conversationKey: selfConversationKey())
    }

    private func selfConversationKey() throws -> Data {
        try NIP44.conversationKey(privateKey: key, peer: key.publicKey)
    }
}

public enum SigningError: Error, Equatable {
    /// The relay signs this kind itself and will reject a client-authored one.
    case relaySignedKind(EventKind)
}
