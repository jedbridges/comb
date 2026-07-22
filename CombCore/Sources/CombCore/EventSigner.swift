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
}

public enum SigningError: Error, Equatable {
    /// The relay signs this kind itself and will reject a client-authored one.
    case relaySignedKind(EventKind)
}
