import Foundation

public extension Zap {
    /// An agent asking a member to spend on its behalf.
    ///
    /// Nothing here is authority. An intent is a request, and every field in it
    /// is the agent's claim about what it wants: the amount it names is what it
    /// is asking for, not what it may have. The funder's device decides, and the
    /// decision needs a grant that the agent cannot see, cannot forge, and is
    /// not told about.
    ///
    /// The `id` is the replay key. One intent buys at most one payment, however
    /// many times it is republished, and the ledger is what remembers that.
    struct Intent: Equatable, Sendable {
        public let id: String
        /// The agent that asked. This is the pubkey a grant names.
        public let agent: String
        /// The channel it asked in, from the `h` tag. A grant is per channel, so
        /// an intent with no channel cannot be matched to one.
        public let channel: String
        public let recipient: String
        /// The message being zapped. Nil means the agent wants to pay the person
        /// rather than a line they wrote.
        public let targetEventID: String?
        public let amountMillisats: Int64
        public let comment: String
        public let createdAt: Int64

        public init(
            id: String,
            agent: String,
            channel: String,
            recipient: String,
            targetEventID: String?,
            amountMillisats: Int64,
            comment: String,
            createdAt: Int64
        ) {
            self.id = id
            self.agent = agent
            self.channel = channel
            self.recipient = recipient
            self.targetEventID = targetEventID
            self.amountMillisats = amountMillisats
            self.comment = comment
            self.createdAt = createdAt
        }

        public var amountSats: Int64 { amountMillisats / 1000 }
        public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    }

    enum IntentError: Error, Equatable {
        case notAnIntent
        case badSignature
        /// No `h` tag. A grant is scoped to a channel, so an intent that names
        /// none can never match one, and guessing the channel from context would
        /// be inventing the scope the reader chose.
        case missingChannel
        case missingRecipient
        /// Absent, unparseable, or not positive. Zero is not a payment and a
        /// negative amount is somebody probing.
        case invalidAmount
    }

    /// Reads an intent, checking only what the event can prove about itself.
    ///
    /// Whether it may be *acted on* is a separate question with a separate
    /// answer, decided against a grant and a ledger the agent has no access to.
    /// Keeping the two apart is what lets the parse be tested exhaustively
    /// without a store, and what stops a malformed intent and an over-budget one
    /// from sharing an error.
    static func intent(from event: NostrEvent) throws -> Intent {
        guard event.kind == .buzzZapIntent else { throw IntentError.notAnIntent }
        guard event.isValid else { throw IntentError.badSignature }

        guard let channel = event.groupID, !channel.isEmpty else {
            throw IntentError.missingChannel
        }
        guard let recipient = event.firstValue(for: "p"), !recipient.isEmpty else {
            throw IntentError.missingRecipient
        }
        guard let raw = event.firstValue(for: "amount"),
              let amount = Int64(raw), amount > 0
        else { throw IntentError.invalidAmount }

        return Intent(
            id: event.id,
            agent: event.pubkey,
            channel: channel,
            recipient: recipient,
            targetEventID: event.firstValue(for: "e"),
            amountMillisats: amount,
            comment: event.content,
            createdAt: event.createdAt
        )
    }

    /// Builds the intent an agent publishes.
    ///
    /// Here so an agent written against this package asks in the shape Comb
    /// reads, and so the tests that matter can build a real one rather than a
    /// hand-assembled approximation of it.
    static func intent(
        amountMillisats: Int64,
        recipient: String,
        groupID: String,
        eventID: String? = nil,
        comment: String = "",
        with signer: any EventSigner
    ) async throws -> NostrEvent {
        var tags: [[String]] = [
            ["h", groupID],
            ["p", recipient],
            ["amount", String(amountMillisats)],
        ]
        if let eventID { tags.append(["e", eventID]) }

        return try await signer.sign(
            kind: .buzzZapIntent,
            content: comment,
            tags: tags
        )
    }
}
