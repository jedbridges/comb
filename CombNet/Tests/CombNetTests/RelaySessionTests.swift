import CombCore
import Foundation
import Testing
@testable import CombNet

@Suite("NIP-42 authentication", .timeLimit(.minutes(1)))
struct AuthenticationTests {
    @Test("answers a challenge with a signed kind 22242 bound to this relay")
    func answersChallenge() async throws {
        let harness = try await Harness()
        try await harness.connect()

        let sent = await harness.transport.sent(ofType: "AUTH")
        #expect(sent.count == 1)

        let event = try #require(sent[0].event)
        #expect(event.kind == .clientAuth)
        #expect(event.isValid)

        let tags = event.tags
        #expect(tags.contains(["challenge", "challenge-abc"]))
        // The relay tag is what stops a signed response being replayed against
        // a different relay.
        #expect(tags.contains(["relay", harness.url.absoluteString]))
    }

    @Test("holds REQs until authentication completes")
    func queuesUntilAuthenticated() async throws {
        // Buzz relays advertise auth_required unconditionally, so a REQ sent
        // before the handshake only earns a CLOSED and a wasted round trip.
        let harness = try await Harness()
        try await harness.session.start()

        let subscribing = Task {
            try await harness.session.subscribe(
                [Filter(kinds: [.groupChatMessage]).inGroup("room-1")]
            )
        }

        // Give the subscribe a chance to reach the relay if it were going to.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.transport.sent(ofType: "REQ").isEmpty)

        await harness.transport.push("[\"AUTH\",\"challenge-abc\"]")
        _ = try await subscribing.value

        #expect(await harness.transport.sent(ofType: "REQ").count == 1)
    }

    @Test("fails a caller that arrives after the rejection has already happened")
    func rejectionIsTerminalForLateCallers() async throws {
        // The ordering that hung CI. On a fast machine the subscribe suspends
        // before the relay's rejection is processed; on a slow two-core runner
        // the rejection lands first, against an empty waiter list. Without a
        // recorded failure the late caller waits for an event that has been and
        // gone, and no timeout exists to rescue it.
        let harness = try await Harness(behaviour: { request, transport in
            if case .auth(let event) = request {
                await transport.push("[\"OK\",\"\(event.id)\",false,\"invalid: bad signature\"]")
            }
        })
        try await harness.session.start()

        await harness.transport.push("[\"AUTH\",\"challenge-abc\"]")
        // Let the rejection be fully processed before anyone asks to subscribe.
        try await waitUntil("auth rejection") {
            await harness.transport.sent(ofType: "AUTH").count == 1
        }
        try await Task.sleep(for: .milliseconds(30))

        await #expect(throws: RelayError.self) {
            try await harness.session.subscribe([Filter(kinds: [.groupChatMessage])])
        }
    }

    @Test("recovers when the relay challenges again after a rejection")
    func recoversAfterRejection() async throws {
        // A recorded failure must not be permanent: a relay may re-challenge and
        // accept, and the session has to come back rather than staying poisoned.
        let attempts = Counter()
        let harness = try await Harness(behaviour: { request, transport in
            if case .auth(let event) = request {
                if await attempts.next() == 1 {
                    await transport.push("[\"OK\",\"\(event.id)\",false,\"invalid: try again\"]")
                } else {
                    await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
                }
            }
        })
        try await harness.session.start()

        await harness.transport.push("[\"AUTH\",\"challenge-1\"]")
        try await Task.sleep(for: .milliseconds(30))
        await harness.transport.push("[\"AUTH\",\"challenge-2\"]")

        try await waitUntil("recovery") { await harness.session.state == .ready }
    }

    @Test("fails waiting callers when the relay rejects authentication")
    func rejectedAuthentication() async throws {
        let harness = try await Harness(behaviour: { request, transport in
            if case .auth(let event) = request {
                await transport.push("[\"OK\",\"\(event.id)\",false,\"invalid: bad signature\"]")
            }
        })
        try await harness.session.start()

        let subscribing = Task {
            try await harness.session.subscribe([Filter(kinds: [.groupChatMessage])])
        }
        await harness.transport.push("[\"AUTH\",\"challenge-abc\"]")

        await #expect(throws: RelayError.self) { try await subscribing.value }
    }
}

@Suite("Filter validation", .timeLimit(.minutes(1)))
struct FilterValidationTests {
    @Test("refuses a filter with no kinds")
    func refusesMissingKinds() async throws {
        // Buzz treats an absent `kinds` as an unscoped query and returns 403
        // rather than serving everything, so this is caught before sending.
        let harness = try await Harness()
        try await harness.connect()

        await #expect(throws: RelayError.filterMissingKinds) {
            try await harness.session.subscribe([Filter().inGroup("room-1")])
        }
        await #expect(throws: RelayError.filterMissingKinds) {
            _ = try await harness.session.query([Filter(kinds: [])])
        }
        #expect(await harness.transport.sent(ofType: "REQ").isEmpty)
    }

    @Test("refuses p-gated kinds without a pubkey scope")
    func refusesUnscopedGatedKinds() async throws {
        let harness = try await Harness()
        try await harness.connect()

        await #expect(throws: RelayError.filterRequiresPubkeyScope) {
            try await harness.session.subscribe([Filter(kinds: [.giftWrap])])
        }
    }

    @Test("accepts p-gated kinds once scoped")
    func acceptsScopedGatedKinds() async throws {
        let harness = try await Harness()
        try await harness.connect()
        let me = try await harness.signer.publicKey().hex

        try await harness.session.subscribe([Filter(kinds: [.giftWrap]).taggingPubkey(me)])
        #expect(await harness.transport.sent(ofType: "REQ").count == 1)
    }
}

@Suite("Subscriptions", .timeLimit(.minutes(1)))
struct SubscriptionTests {
    @Test("routes events to the sink and reports end of stored events")
    func routesEvents() async throws {
        let harness = try await Harness(behaviour: Behaviour.cooperative(onReq: { _, _ in }))
        try await harness.connect()

        let id = try await harness.session.subscribe(
            [Filter(kinds: [.groupChatMessage]).inGroup("room-1")]
        )

        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage, content: "hello", tags: [["h", "room-1"]], with: key
        )
        try await harness.transport.push(event: event, subscription: id)
        await harness.transport.push("[\"EOSE\",\"\(id)\"]")

        try await waitUntil("event delivery") { await harness.sink.events.count == 1 }
        #expect(await harness.sink.events.first == event)
        #expect(await harness.sink.eoseSubscriptions == [id])
    }

    @Test("ignores events for an unknown subscription")
    func ignoresUnknownSubscription() async throws {
        // Stale frames arrive after a CLOSE or across a reconnect. Delivering
        // them would attribute events to a subscription nobody is watching.
        let harness = try await Harness()
        try await harness.connect()

        let key = try PrivateKey()
        let event = try NostrEvent.signed(kind: .groupChatMessage, content: "stale", with: key)
        try await harness.transport.push(event: event, subscription: "s999")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await harness.sink.events.isEmpty)
        #expect(await harness.session.state == .ready)
    }

    @Test("closing a subscription sends CLOSE")
    func unsubscribeSendsClose() async throws {
        let harness = try await Harness()
        try await harness.connect()

        let id = try await harness.session.subscribe([Filter(kinds: [.groupChatMessage])])
        await harness.session.unsubscribe(id)

        try await waitUntil("CLOSE") { await harness.transport.sent(ofType: "CLOSE").count == 1 }
        #expect(await harness.transport.sent(ofType: "CLOSE")[0].subscriptionID == id)
    }

    @Test("gives each subscription a distinct id")
    func distinctIDs() async throws {
        let harness = try await Harness()
        try await harness.connect()

        let first = try await harness.session.subscribe([Filter(kinds: [.groupChatMessage])])
        let second = try await harness.session.subscribe([Filter(kinds: [.reaction])])
        #expect(first != second)
    }
}

@Suite("Queries", .timeLimit(.minutes(1)))
struct QueryTests {
    @Test("collects stored events and resolves on EOSE")
    func resolvesOnEOSE() async throws {
        let key = try PrivateKey()
        let events = try (0..<3).map {
            try NostrEvent.signed(
                kind: .groupMetadata,
                content: "{\"name\":\"room \($0)\"}",
                tags: [["d", "room-\($0)"]],
                with: key
            )
        }

        let harness = try await Harness(behaviour: Behaviour.cooperative(onReq: { id, transport in
            for event in events { try? await transport.push(event: event, subscription: id) }
            await transport.push("[\"EOSE\",\"\(id)\"]")
        }))
        try await harness.connect()

        let result = try await harness.session.query([Filter(kinds: [.groupMetadata])])

        #expect(result == events)
        // A one-shot must close itself, or it would leak a subscription slot
        // against the relay's max_subscriptions.
        #expect(await harness.transport.sent(ofType: "CLOSE").count == 1)
    }

    @Test("does not route query results to the sink")
    func queryBypassesSink() async throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(kind: .groupMetadata, content: "{}", with: key)

        let harness = try await Harness(behaviour: Behaviour.cooperative(onReq: { id, transport in
            try? await transport.push(event: event, subscription: id)
            await transport.push("[\"EOSE\",\"\(id)\"]")
        }))
        try await harness.connect()

        _ = try await harness.session.query([Filter(kinds: [.groupMetadata])])
        #expect(await harness.sink.events.isEmpty)
    }

    @Test("fails when the relay closes the query")
    func failsOnClosed() async throws {
        let harness = try await Harness(behaviour: Behaviour.cooperative(onReq: { id, transport in
            await transport.push("[\"CLOSED\",\"\(id)\",\"error: too many filters\"]")
        }))
        try await harness.connect()

        await #expect(throws: RelayError.subscriptionClosed("error: too many filters")) {
            _ = try await harness.session.query([Filter(kinds: [.groupMetadata])])
        }
    }

    @Test("times out rather than suspending forever")
    func timesOut() async throws {
        // A relay that accepts a REQ and never sends EOSE would otherwise leave
        // the caller hanging with no way to recover.
        let harness = try await Harness(behaviour: Behaviour.cooperative(onReq: { _, _ in }))
        try await harness.connect()

        await #expect(throws: RelayError.timedOut) {
            _ = try await harness.session.query(
                [Filter(kinds: [.groupMetadata])],
                timeout: .milliseconds(10)
            )
        }
    }
}

@Suite("Publishing", .timeLimit(.minutes(1)))
struct PublishTests {
    private func message(_ text: String) throws -> NostrEvent {
        try NostrEvent.signed(
            kind: .groupChatMessage,
            content: text,
            tags: [["h", "room-1"]],
            with: try PrivateKey()
        )
    }

    @Test("resolves when the relay accepts")
    func resolvesOnOK() async throws {
        let harness = try await Harness()
        try await harness.connect()

        try await harness.session.publish(try message("hello"))
        #expect(await harness.transport.sent(ofType: "EVENT").count == 1)
    }

    @Test("throws the relay's reason when rejected")
    func throwsOnRejection() async throws {
        let harness = try await Harness(behaviour: { request, transport in
            switch request {
            case .auth(let event):
                await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
            case .event(let event):
                await transport.push("[\"OK\",\"\(event.id)\",false,\"restricted: not a member\"]")
            default:
                break
            }
        })
        try await harness.connect()

        await #expect(throws: RelayError.publishRejected("restricted: not a member")) {
            try await harness.session.publish(try message("nope"))
        }
    }

    @Test("routes each OK to the publish that caused it")
    func routesConcurrentPublishes() async throws {
        // Two sends in flight at once must not resolve each other. The event id
        // is the correlation key, which is why it has to be computed before
        // sending rather than assigned by the relay.
        let first = try message("first")
        let second = try message("second")

        let harness = try await Harness(behaviour: { request, transport in
            switch request {
            case .auth(let event):
                await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
            case .event(let event):
                if event.id == second.id {
                    await transport.push("[\"OK\",\"\(event.id)\",false,\"invalid: nope\"]")
                } else {
                    await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
                }
            default:
                break
            }
        })
        try await harness.connect()

        try await harness.session.publish(first)
        await #expect(throws: RelayError.publishRejected("invalid: nope")) {
            try await harness.session.publish(second)
        }
    }

    @Test("refuses to publish relay-signed kinds")
    func refusesRelaySignedKinds() async throws {
        // The relay authors 39000 itself. Sending one is a programming error
        // worth catching locally.
        let harness = try await Harness()
        try await harness.connect()

        let event = NostrEvent(
            id: "x", pubkey: "y", createdAt: 0,
            kind: .groupMetadata, tags: [], content: "", sig: "z"
        )
        await #expect(throws: RelayError.self) {
            try await harness.session.publish(event)
        }
        #expect(await harness.transport.sent(ofType: "EVENT").isEmpty)
    }
}

@Suite("Recovery", .timeLimit(.minutes(1)))
struct RecoveryTests {
    @Test("re-authenticates and retries once when a subscription is auth-closed")
    func retriesAfterAuthFailure() async throws {
        // A relay that restarted forgets we authenticated and closes live
        // subscriptions with auth-required. Without this the app goes silently
        // deaf: connected, subscribed, receiving nothing.
        let closedOnce = Counter()

        let harness = try await Harness(behaviour: { request, transport in
            switch request {
            case .auth(let event):
                await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
            case .req(let id, _):
                if await closedOnce.next() == 1 {
                    await transport.push("[\"CLOSED\",\"\(id)\",\"auth-required: please auth\"]")
                    // The relay re-challenges, as it does after a restart.
                    await transport.push("[\"AUTH\",\"challenge-2\"]")
                } else {
                    await transport.push("[\"EOSE\",\"\(id)\"]")
                }
            default:
                break
            }
        })
        try await harness.connect()

        let id = try await harness.session.subscribe(
            [Filter(kinds: [.groupChatMessage]).inGroup("room-1")]
        )

        try await waitUntil("resubscribe") {
            await harness.transport.sent(ofType: "REQ").count == 2
        }
        let reqs = await harness.transport.sent(ofType: "REQ")
        #expect(reqs[1].subscriptionID == id, "the retry reuses the same subscription id")
    }

    @Test("does not retry a subscription the relay says is forbidden")
    func doesNotRetryRestricted() async throws {
        // restricted: means this pubkey may not have this, ever. Re-authenticating
        // changes nothing, so retrying would just hammer the relay.
        let harness = try await Harness(behaviour: { request, transport in
            switch request {
            case .auth(let event):
                await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
            case .req(let id, _):
                await transport.push("[\"CLOSED\",\"\(id)\",\"restricted: not a member\"]")
            default:
                break
            }
        })
        try await harness.connect()

        _ = try await harness.session.subscribe([Filter(kinds: [.groupChatMessage])])

        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.transport.sent(ofType: "REQ").count == 1)
    }

    @Test("reconnects and resubscribes from just before the last event seen")
    func resubscribesWithSince() async throws {
        let harness = try await Harness(behaviour: Behaviour.cooperative(onReq: { _, _ in }))
        try await harness.connect()

        let id = try await harness.session.subscribe(
            [Filter(kinds: [.groupChatMessage]).inGroup("room-1")]
        )

        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "last before outage",
            tags: [["h", "room-1"]],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            with: try PrivateKey()
        )
        try await harness.transport.push(event: event, subscription: id)
        try await waitUntil("first event") { await harness.sink.events.count == 1 }

        await harness.transport.reset()
        await harness.transport.drop()

        // The reconnect re-opens, re-authenticates, and replays.
        try await waitUntil("reopen") { await harness.transport.openCount == 2 }
        await harness.transport.push("[\"AUTH\",\"challenge-2\"]")
        try await waitUntil("resubscribe") {
            await !harness.transport.sent(ofType: "REQ").isEmpty
        }

        let filter = try #require(await harness.transport.sent(ofType: "REQ").first?.filters.first)
        let since = try #require(filter.since)
        // Five seconds of overlap: relay clocks drift and many events share a
        // second, so resuming exactly at the last timestamp drops messages. The
        // duplicates are free because the store keys on event id.
        #expect(since == 1_700_000_000 - 5)
        #expect(filter.tags["h"] == ["room-1"])
    }

    @Test("fails in-flight publishes when the connection drops")
    func failsPublishesOnDrop() async throws {
        // The relay will never send an OK for a socket that no longer exists,
        // so a caller left suspended would hang forever. The outbox is what
        // makes retrying safe.
        let harness = try await Harness(behaviour: { request, transport in
            if case .auth(let event) = request {
                await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
            }
            // Publishes are deliberately never acknowledged.
        })
        try await harness.connect()

        let event = try NostrEvent.signed(
            kind: .groupChatMessage, content: "lost", tags: [["h", "room-1"]],
            with: try PrivateKey()
        )

        let publishing = Task { try await harness.session.publish(event) }
        try await Task.sleep(for: .milliseconds(20))
        await harness.transport.drop()

        await #expect(throws: RelayError.notConnected) { try await publishing.value }
    }

    @Test("stopping fails everything waiting instead of hanging")
    func stopReleasesWaiters() async throws {
        let harness = try await Harness(behaviour: { _, _ in })
        try await harness.session.start()

        let subscribing = Task {
            try await harness.session.subscribe([Filter(kinds: [.groupChatMessage])])
        }
        try await Task.sleep(for: .milliseconds(20))
        await harness.session.stop()

        await #expect(throws: RelayError.notConnected) { _ = try await subscribing.value }
        #expect(await harness.session.state == .stopped)
    }

    @Test("survives an unparseable frame")
    func survivesGarbage() async throws {
        // Relays add message types. Treating an unknown one as fatal would take
        // the app down for something it could safely ignore.
        let harness = try await Harness()
        try await harness.connect()

        await harness.transport.push("this is not json")
        await harness.transport.push("[\"FUTURE_MESSAGE\",\"payload\"]")
        await harness.transport.push("{}")

        try await Task.sleep(for: .milliseconds(30))
        #expect(await harness.session.state == .ready)

        try await harness.session.subscribe([Filter(kinds: [.groupChatMessage])])
        #expect(await harness.transport.sent(ofType: "REQ").count == 1)
    }
}

@Suite("Reconnect policy", .timeLimit(.minutes(1)))
struct ReconnectPolicyTests {
    @Test("backs off exponentially up to the cap")
    func backsOff() {
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30))
        // Full jitter at its maximum, to assert the ceiling rather than a sample.
        let ceiling: (Int) -> Duration = { policy.delay(forAttempt: $0) { $0.upperBound } }

        #expect(ceiling(1) == .seconds(1))
        #expect(ceiling(2) == .seconds(2))
        #expect(ceiling(3) == .seconds(4))
        #expect(ceiling(4) == .seconds(8))
        #expect(ceiling(5) == .seconds(16))
        #expect(ceiling(6) == .seconds(30), "capped")
        #expect(ceiling(50) == .seconds(30), "still capped, no overflow")
    }

    @Test("jitters between zero and the ceiling")
    func jitters() {
        // Full jitter rather than a fixed backoff, so a relay restart does not
        // bring every client back in the same instant.
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30))

        #expect(policy.delay(forAttempt: 3) { $0.lowerBound } == .zero)
        #expect(policy.delay(forAttempt: 3) { $0.upperBound } == .seconds(4))
        #expect(policy.delay(forAttempt: 3) { _ in 0.5 } == .seconds(2))
    }

    @Test("returns no delay for a zeroth attempt")
    func zerothAttempt() {
        #expect(ReconnectPolicy.default.delay(forAttempt: 0) == .zero)
    }
}

/// A counter usable from a `@Sendable` behaviour closure.
actor Counter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
