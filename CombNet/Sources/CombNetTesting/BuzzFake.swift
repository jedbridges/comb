import CombCore
import CombNet
import Foundation

/// A relay that says no.
///
/// `MockTransport` answers OK to everything and evaluates no filters, which
/// makes it a fine transport fixture and a useless conformance target: a client
/// that stopped sending `h` tags, or subscribed to kinds a real relay gates
/// behind a `#p` scope, would pass against it. This enforces the rules Comb
/// actually depends on, so a case that passes here is evidence about the
/// protocol rather than about the fake.
///
/// It is a `WebSocketTransport`, so it plugs in exactly where the real socket
/// does and the entire client stack above it runs unmodified.
///
/// Every rule is individually switchable through `Rules`. That is not
/// configurability for its own sake: a conformance suite that cannot fail is
/// decoration, and the only way to know a case is testing the rule it names is
/// to turn that rule off and watch the case go red.
public actor BuzzFake: WebSocketTransport {
    /// Which rules this relay enforces. Everything on by default; a test turns
    /// one off to prove the case that covers it is load-bearing.
    public struct Rules: Sendable {
        /// Refuse EVENTs and REQs from a socket that has not completed NIP-42.
        public var requiresAuthentication = true
        /// Answer a REQ with the events that match its filters, rather than
        /// everything or nothing.
        public var evaluatesFilters = true
        /// Refuse to publish into a group the author is not a member of, and
        /// refuse to serve that group's events to a non-member.
        public var scopesToGroupMembership = true
        /// Refuse an event whose kind the relay signs itself.
        public var rejectsRelaySignedKinds = true
        /// Refuse a subscription for gift wraps or membership notices that is
        /// not scoped to a pubkey with `#p`.
        public var gatesPubkeyScopedKinds = true
        /// Check the auth response quotes the challenge we issued.
        public var matchesAuthChallenge = true
        /// Check the auth response names this relay, so a signature collected
        /// elsewhere cannot be replayed here.
        public var matchesAuthRelayURL = true
        /// How far from now an auth response's `created_at` may be.
        public var authWindow: Int64 = 600
        /// Answer group state (39000, 39002) only to a historical query, never
        /// on a live subscription. This is a Buzz behaviour rather than a
        /// NIP-29 requirement, and it is the entire reason `refreshGroupState`
        /// exists in the client.
        public var withholdsGroupStateFromLiveSubscriptions = true

        public init() {}
    }

    public struct Group: Sendable {
        public var id: String
        public var name: String
        public var members: Set<String>
        public var admins: Set<String>
        /// Buzz's hidden groups, made by the 41010 command rather than 9007.
        public var isDirectMessage: Bool

        public init(
            id: String,
            name: String,
            members: Set<String>,
            admins: Set<String> = [],
            isDirectMessage: Bool = false
        ) {
            self.id = id
            self.name = name
            self.members = members
            self.admins = admins
            self.isDirectMessage = isDirectMessage
        }
    }

    public private(set) var rules: Rules
    /// The relay's own identity, for the events it signs itself. A client that
    /// checks provenance on 39000/39002 is checking against this.
    public nonisolated let relayKey: PrivateKey
    public private(set) var stored: [NostrEvent] = []
    public private(set) var groups: [String: Group] = [:]
    public private(set) var authenticatedAs: String?
    public private(set) var sentFrames: [Data] = []

    private var url: URL?
    /// The challenge this connection issued. Public so a case can answer it
    /// the way a hostile client would.
    public private(set) var challenge = "challenge-0"
    private var challengeCount = 0
    private var subscriptions: [String: [Filter]] = [:]
    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var failure: Error?

    public init(rules: Rules = Rules(), relayKey: PrivateKey? = nil) throws {
        self.rules = rules
        self.relayKey = try relayKey ?? PrivateKey()
    }

    // MARK: - Seeding

    /// Puts a group and its roster in place without going through 9007, for
    /// cases whose subject is something else.
    public func seed(group: Group) {
        groups[group.id] = group
        for item in groupState(for: group) { record(item) }
    }

    /// Stores events as though they had arrived before this client connected,
    /// which is what a REQ's historical answer is made of.
    public func seed(events: [NostrEvent]) {
        for event in events { record(event) }
    }

    public func loosen(_ change: @Sendable (inout Rules) -> Void) {
        change(&rules)
    }

    // MARK: - WebSocketTransport

    public func open(url: URL) async throws {
        self.url = url
        failure = nil
        authenticatedAs = nil
        subscriptions.removeAll()

        // A fresh challenge per connection, so a response captured on an
        // earlier socket cannot be replayed on this one.
        challengeCount += 1
        challenge = "challenge-\(challengeCount)"
        push("[\"AUTH\",\"\(challenge)\"]")
    }

    public func send(_ frame: Data) async throws {
        if let failure { throw failure }
        sentFrames.append(frame)
        guard let request = RelayRequest(frame: frame) else { return }

        switch request {
        case .auth(let event):
            handleAuth(event)
        case .event(let event):
            handleEvent(event)
        case .req(let id, let filters):
            handleRequest(id: id, filters: filters)
        case .close(let id):
            subscriptions.removeValue(forKey: id)
        }
    }

    public func receive() async throws -> Data {
        if let failure, inbox.isEmpty { throw failure }
        if !inbox.isEmpty { return inbox.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Closing fails anything parked in `receive()`, which is what a real
    /// socket does and what a fake that merely forgot its subscriptions does
    /// not. Without it, a second session opening on the same relay hands its
    /// challenge to the read loop of the first, which is still waiting, and
    /// then times out waiting for an answer that went somewhere else.
    public func close() async {
        subscriptions.removeAll()
        drop()
    }

    /// Simulates the connection dropping.
    public func drop(_ error: Error = TransportError.notOpen) {
        failure = error
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
    }

    /// Frames the client sent, decoded for assertions.
    public func sent() -> [SentFrame] {
        sentFrames.compactMap(SentFrame.init(frame:))
    }

    public func sent(ofType type: String) -> [SentFrame] {
        sent().filter { $0.type == type }
    }

    // MARK: - NIP-42

    private func handleAuth(_ event: NostrEvent) {
        guard event.kind == .clientAuth, event.isValid else {
            return ok(event.id, false, "invalid: not a valid auth event")
        }

        if rules.matchesAuthChallenge {
            guard tag(event, "challenge") == challenge else {
                return ok(event.id, false, "restricted: wrong challenge")
            }
        }

        if rules.matchesAuthRelayURL {
            // Host rather than the whole string: a client may normalise the
            // trailing slash or the scheme, and a real relay compares the
            // authority. What must not pass is a response naming someone else.
            let claimed = tag(event, "relay").flatMap { URL(string: $0)?.host }
            guard let claimed, claimed == url?.host else {
                return ok(event.id, false, "restricted: auth event is for a different relay")
            }
        }

        let age = abs(Int64(Date().timeIntervalSince1970) - event.createdAt)
        guard age <= rules.authWindow else {
            return ok(event.id, false, "restricted: auth event is too old")
        }

        authenticatedAs = event.pubkey
        ok(event.id, true, "")
    }

    // MARK: - Publishing

    private func handleEvent(_ event: NostrEvent) {
        if rules.rejectsRelaySignedKinds, event.kind.isRelaySigned {
            return ok(event.id, false, "invalid: kind \(event.kind) is signed by the relay")
        }
        guard event.isValid else {
            return ok(event.id, false, "invalid: signature does not verify")
        }
        if rules.requiresAuthentication, authenticatedAs == nil {
            return ok(event.id, false, "auth-required: we only accept events from authenticated users")
        }
        if rules.requiresAuthentication, event.pubkey != authenticatedAs {
            return ok(event.id, false, "restricted: you cannot publish as somebody else")
        }
        if stored.contains(where: { $0.id == event.id }) {
            // NIP-01: a duplicate is accepted, not refused. The client's outbox
            // leans on this, because resending after a lost OK is its whole
            // recovery strategy.
            return ok(event.id, true, "duplicate: already have this event")
        }

        switch event.kind {
        case .groupCreate:
            return createGroup(from: event)
        case .groupJoinRequest:
            return changeMembership(from: event, joining: true)
        case .groupLeaveRequest:
            return changeMembership(from: event, joining: false)
        case .buzzOpenDirectMessage:
            return openDirectMessage(from: event)
        default:
            break
        }

        if Self.requiresGroupScope(event.kind) {
            guard let group = tag(event, "h") else {
                return ok(event.id, false, "invalid: missing h tag")
            }
            if rules.scopesToGroupMembership {
                guard groups[group]?.members.contains(event.pubkey) == true else {
                    return ok(event.id, false, "restricted: you are not a member of that group")
                }
            }
        }

        // Ephemerals reach live subscribers and are never kept, which is what
        // makes a typing indicator safe to send and pointless to store.
        if !event.kind.isEphemeral { record(event) }
        ok(event.id, true, "")
        deliverLive(event)
    }

    /// Stores an event, applying NIP-01's storage classes.
    ///
    /// Replacement is not a detail: read-state sync publishes a 30078 per
    /// change under the same `d` tag and relies on the relay keeping only the
    /// newest. A fake that kept them all would answer a query with a pile of
    /// superseded markers and never notice the difference.
    private func record(_ event: NostrEvent) {
        if event.kind.isAddressable {
            let identifier = tag(event, "d") ?? ""
            stored.removeAll {
                $0.kind == event.kind && $0.pubkey == event.pubkey
                    && (tag($0, "d") ?? "") == identifier && $0.createdAt <= event.createdAt
            }
        } else if event.kind.isReplaceable {
            stored.removeAll {
                $0.kind == event.kind && $0.pubkey == event.pubkey && $0.createdAt <= event.createdAt
            }
        }
        stored.append(event)
    }

    /// Buzz's 41010: the relay makes the group, names it, adds everyone, and
    /// answers with the channel id inside the OK's reason.
    ///
    /// The reason string is the only place in the protocol where an
    /// acknowledgement carries data the client needs, which is exactly why it
    /// deserves a contract case: nothing else in Comb reads an OK for anything
    /// but yes or no.
    private func openDirectMessage(from event: NostrEvent) {
        let named = event.tags.filter { $0.first == "p" && $0.count > 1 }.map { $0[1] }
        guard !named.isEmpty else {
            return ok(event.id, false, "invalid: a conversation needs somebody in it")
        }
        let participants = Set(named).union([event.pubkey])

        // Keyed on the participant set, so asking twice returns the same
        // conversation rather than making a second one. The app leans on this:
        // tapping "message" on a profile is not meant to be destructive.
        let existing = groups.values.first { $0.isDirectMessage && $0.members == participants }
        let id = existing?.id ?? "dm-\(abs(participants.sorted().joined().hashValue))"

        if existing == nil {
            let group = Group(
                id: id,
                name: participants.sorted().map { String($0.prefix(8)) }.joined(separator: " & "),
                members: participants,
                isDirectMessage: true
            )
            groups[id] = group
            let state = groupState(for: group)
            for item in state {
                record(item)
                deliverLive(item)
            }
        }

        record(event)
        ok(event.id, true, "response: {\"channel_id\":\"\(id)\"}")
    }

    private func createGroup(from event: NostrEvent) {
        let id = tag(event, "h") ?? event.id
        let name = tag(event, "name") ?? id
        groups[id] = Group(
            id: id,
            name: name,
            members: [event.pubkey],
            admins: [event.pubkey]
        )
        record(event)
        ok(event.id, true, "")

        // Offered to the live subscriptions and withheld there, rather than
        // simply never offered. The difference matters: if this did not go
        // through `deliverLive`, the rule that withholds it would be doing
        // nothing, and the case that claims to test the rule would pass against
        // a relay that had no such behaviour at all.
        for item in groupState(for: groups[id]!) {
            record(item)
            deliverLive(item)
        }
    }

    private func changeMembership(from event: NostrEvent, joining: Bool) {
        guard let id = tag(event, "h"), var group = groups[id] else {
            return ok(event.id, false, "invalid: no such group")
        }

        if joining {
            group.members.insert(event.pubkey)
        } else {
            group.members.remove(event.pubkey)
        }
        groups[id] = group
        record(event)
        ok(event.id, true, "")

        // The roster notice is relay-signed and does reach a live subscription:
        // it is how a running client learns its own membership changed. The
        // group state it implies does not, which is the asymmetry the client's
        // refresh-on-notice exists to bridge.
        let notice = try? NostrEvent.signed(
            kind: joining ? .buzzMemberAdded : .buzzMemberRemoved,
            content: "",
            tags: [["h", id], ["p", event.pubkey]],
            with: relayKey
        )
        if let notice {
            record(notice)
            deliverLive(notice)
        }
        // The new roster supersedes the old one by the addressable-replacement
        // rule in `record`, rather than by a hand-written removal here.
        for item in groupState(for: group) where item.kind == .groupMembers {
            record(item)
            deliverLive(item)
        }
    }

    /// The relay-signed description of a group: its metadata and its roster.
    private func groupState(for group: Group) -> [NostrEvent] {
        let metadata = try? NostrEvent.signed(
            kind: .groupMetadata,
            content: "",
            tags: [["d", group.id], ["name", group.name]],
            with: relayKey
        )
        let members = try? NostrEvent.signed(
            kind: .groupMembers,
            content: "",
            tags: [["d", group.id]] + group.members.sorted().map { ["p", $0] },
            with: relayKey
        )
        return [metadata, members].compactMap { $0 }
    }

    // MARK: - Subscribing

    private func handleRequest(id: String, filters: [Filter]) {
        if rules.requiresAuthentication, authenticatedAs == nil {
            return closed(id, "auth-required: we only serve authenticated users")
        }
        if rules.gatesPubkeyScopedKinds, filters.contains(where: \.needsPubkeyScope) {
            return closed(id, "restricted: these kinds need a #p scope")
        }
        if rules.gatesPubkeyScopedKinds,
           let me = authenticatedAs,
           filters.contains(where: { filter in
               filter.tags["p"].map { !$0.contains(me) } ?? false
                   && filter.kinds?.contains(where: Filter.pGatedKinds.contains) == true
           }) {
            return closed(id, "restricted: you may only scope those kinds to yourself")
        }

        subscriptions[id] = filters

        for event in answer(to: filters) {
            emit(event, on: id)
        }
        push("[\"EOSE\",\"\(id)\"]")
    }

    /// The historical answer: everything stored that matches, newest first,
    /// truncated to the smallest limit any filter asked for.
    private func answer(to filters: [Filter]) -> [NostrEvent] {
        guard rules.evaluatesFilters else { return stored }

        var matched: [NostrEvent] = []
        for filter in filters {
            var hits = stored
                .filter { filter.matches($0) && isVisible($0) }
                .sorted { $0.createdAt > $1.createdAt }
            if let limit = filter.limit { hits = Array(hits.prefix(limit)) }
            matched.append(contentsOf: hits)
        }

        var seen = Set<String>()
        return matched.filter { seen.insert($0.id).inserted }
    }

    /// Whether the authenticated user is allowed to see an event at all. A
    /// group's traffic belongs to its members, so a relay that served it to
    /// anybody who asked would make the roster decorative.
    private func isVisible(_ event: NostrEvent) -> Bool {
        guard rules.scopesToGroupMembership else { return true }
        guard let me = authenticatedAs else { return false }

        let group = tag(event, "h") ?? (event.kind.isAddressable ? tag(event, "d") : nil)
        guard let group, let roster = groups[group] else { return true }
        return roster.members.contains(me)
    }

    private func deliverLive(_ event: NostrEvent) {
        if rules.withholdsGroupStateFromLiveSubscriptions,
           event.kind == .groupMetadata || event.kind == .groupMembers {
            return
        }
        guard isVisible(event) else { return }

        for (id, filters) in subscriptions
        where !rules.evaluatesFilters || filters.contains(where: { $0.matches(event) }) {
            emit(event, on: id)
        }
    }

    // MARK: - Framing

    private func emit(_ event: NostrEvent, on subscription: String) {
        guard let json = try? JSONEncoder().encode(event) else { return }
        push("[\"EVENT\",\"\(subscription)\",\(String(decoding: json, as: UTF8.self))]")
    }

    /// The reason is JSON-encoded rather than interpolated between quotes. It
    /// carries a JSON object of its own for the 41010 command, and a hand-built
    /// frame would have produced something no client could parse.
    private func ok(_ eventID: String, _ accepted: Bool, _ reason: String) {
        push("[\"OK\",\"\(eventID)\",\(accepted),\(quoted(reason))]")
    }

    private func closed(_ subscription: String, _ reason: String) {
        push("[\"CLOSED\",\"\(subscription)\",\(quoted(reason))]")
    }

    private func quoted(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private func push(_ text: String) {
        let data = Data(text.utf8)
        if waiters.isEmpty {
            inbox.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    private func tag(_ event: NostrEvent, _ name: String) -> String? {
        event.tags.first { $0.first == name && $0.count > 1 }?[1]
    }

    /// Kinds a Buzz relay will not accept without an `h` tag naming a group the
    /// author belongs to. Profile metadata, app data and reports are account
    /// level and carry no group.
    static func requiresGroupScope(_ kind: EventKind) -> Bool {
        switch kind {
        case .groupChatMessage, .reaction, .deletion, .groupDeleteEvent,
             .buzzEdit, .buzzRichContent, .buzzTyping, .buzzPresence,
             .groupAddUser, .groupRemoveUser, .groupEditMetadata:
            true
        default:
            false
        }
    }
}

// MARK: - Filter evaluation

public extension Filter {
    /// Whether an event satisfies this filter, by NIP-01's rules: fields are
    /// ANDed, values within a field are ORed, and an omitted field constrains
    /// nothing.
    ///
    /// This lives with the fake rather than in CombNet because it is relay
    /// behaviour. The client never evaluates a filter; it sends one and trusts
    /// the answer, and that trust is exactly what a contract suite is for.
    func matches(_ event: NostrEvent) -> Bool {
        if let ids, !ids.contains(event.id) { return false }
        if let authors, !authors.contains(event.pubkey) { return false }
        if let kinds, !kinds.contains(event.kind) { return false }
        if let since, event.createdAt < since { return false }
        if let until, event.createdAt > until { return false }

        for (name, wanted) in tags {
            let present = event.tags
                .filter { $0.first == name && $0.count > 1 }
                .map { $0[1] }
            if !present.contains(where: wanted.contains) { return false }
        }
        return true
    }
}
