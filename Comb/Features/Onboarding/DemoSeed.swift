#if DEBUG
import CombCore
import CombStore
import Foundation

/// Seeds a store with a plausible conversation, for working on the UI without
/// a relay or a real key. Debug builds only; the button that triggers it does
/// not exist in release.
enum DemoSeed {
    /// Builds and signs the fixture set. Every event goes through the same
    /// verified ingest as real traffic, so the demo cannot mask a validation
    /// bug.
    static func seed(into store: EventStore, as me: PrivateKey) async throws {
        let ada = try Persona(name: "Ada", about: "type systems and typefaces")
        let mies = try Persona(name: "Mies", about: "less, but better")
        let ray = try Persona(name: "Ray", about: "plywood optimist")

        var events: [NostrEvent] = []
        let now = Int64(Date().timeIntervalSince1970)
        let channel = "demo-general"

        // Group state, relay-shaped: metadata and roster are normally
        // relay-signed, so they are signed here by a standalone key standing in
        // for the relay.
        let relayKey = try PrivateKey()
        events.append(try NostrEvent.signed(
            kind: .groupMetadata,
            content: #"{"name":"General","about":"The main room"}"#,
            tags: [["d", channel]],
            createdAt: date(now - 90_000),
            with: relayKey
        ))
        events.append(try NostrEvent.signed(
            kind: .groupMembers,
            content: "",
            tags: [
                ["d", channel],
                ["p", ada.key.publicKey.hex],
                ["p", mies.key.publicKey.hex],
                ["p", ray.key.publicKey.hex],
            ],
            createdAt: date(now - 90_000),
            with: relayKey
        ))

        events.append(contentsOf: try [ada, mies, ray].map { try $0.profile(at: now - 86_000) })

        // A conversation with the shapes the timeline has to handle: runs by
        // one author, replies, an edit, a reaction pile, a deletion, and the
        // inline emphasis a Buzz composer writes as Markdown.
        let script: [(Persona, String, Int64)] = [
            (ada, "Morning all. I pushed the new grid to the shared canvas.", 7200),
            (ada, "It is eight columns now. Fight me.", 7150),
            (mies, "Eight is defensible. *Twelve* was noise.", 6900),
            (ray, "As long as the **gutters** breathe, I am happy.", 6600),
            (mies, "Gutters at `20` then. The tokens already agree.", 6300),
            (ada, "Done. Also renamed the spacing scale, sorry in advance.", 4800),
            (ray, "You renamed it AGAIN?", 4700),
            (ada, "~~Last time~~. Probably.", 4650),
            (mies, "Shipping the type ramp tonight. Reviews welcome tomorrow.", 1800),
            (ray, "I will bring opinions and pastries.", 900),
        ]

        var scripted: [NostrEvent] = []
        for (persona, text, age) in script {
            scripted.append(try persona.message(text, in: channel, at: now - age))
        }
        events.append(contentsOf: scripted)

        // Reactions on the argumentative one, an edit, and a deletion.
        let contested = scripted[1]
        for persona in [mies, ray] {
            events.append(try NostrEvent.signed(
                kind: .reaction,
                content: "🐝",
                tags: [["e", contested.id]],
                createdAt: date(now - 7000),
                with: persona.key
            ))
        }
        events.append(try NostrEvent.signed(
            kind: .reaction,
            content: "🔥",
            tags: [["e", contested.id]],
            createdAt: date(now - 6950),
            with: ray.key
        ))

        events.append(try NostrEvent.signed(
            kind: .buzzEdit,
            content: "It is eight columns now. Discuss.",
            tags: [["e", contested.id]],
            createdAt: date(now - 7100),
            with: ada.key
        ))

        let regretted = try ray.message("wait wrong channel", in: channel, at: now - 4600)
        events.append(regretted)
        events.append(try NostrEvent.signed(
            kind: .deletion,
            content: "",
            tags: [["e", regretted.id]],
            createdAt: date(now - 4590),
            with: ray.key
        ))

        // A second, quieter channel so the list shows ordering.
        events.append(try NostrEvent.signed(
            kind: .groupMetadata,
            content: #"{"name":"Fonts","about":"Letterforms only"}"#,
            tags: [["d", "demo-fonts"]],
            createdAt: date(now - 90_000),
            with: relayKey
        ))
        events.append(try mies.message(
            "Reminder that Univers is not a personality.",
            in: "demo-fonts",
            at: now - 40_000
        ))

        // Two direct messages, because Buzz names them "dm" and "Group DM (3)"
        // on the wire and Comb has to retitle both from the roster. Without
        // these the demo cannot show the state at all, and the naming rule is
        // only ever exercised by unit tests.
        //
        // The `hidden` tag is the marker the relay actually sends
        // (`side_effects.rs`: "NIP-29 hidden tag: hint to clients not to show
        // DMs in public group lists"), so the fixture carries it verbatim.
        events.append(contentsOf: try directMessage(
            id: "demo-dm-ada",
            relayName: "dm",
            members: [ada],
            me: me,
            relayKey: relayKey,
            at: now - 90_000
        ))
        events.append(try ada.message(
            "Did you get a look at the revised masthead?",
            in: "demo-dm-ada",
            at: now - 7_000
        ))

        events.append(contentsOf: try directMessage(
            id: "demo-dm-group",
            relayName: "Group DM (4)",
            members: [ada, mies, ray],
            me: me,
            relayKey: relayKey,
            at: now - 90_000
        ))
        events.append(try ray.message(
            "Pulling you three in so we stop having this in four places.",
            in: "demo-dm-group",
            at: now - 20_000
        ))

        let result = try await store.ingest(events)
        assert(result.rejected.isEmpty, "demo fixtures must survive verification")

        // The user's own profile, plus the two send states the write path can
        // leave behind: a message still waiting on the relay, and one the relay
        // refused. Both go through the real outbox.
        _ = try await store.ingest([
            try NostrEvent.signed(
                kind: .metadata,
                content: #"{"display_name":"Jed"}"#,
                createdAt: date(now - 86_000),
                with: me
            ),
        ])

        let pending = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "Sending this from Comb.",
            tags: [["h", channel]],
            createdAt: date(now - 60),
            with: me
        )
        try await store.enqueue(pending, channel: channel)

        let refused = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "This one did not send.",
            tags: [["h", channel]],
            createdAt: date(now - 30),
            with: me
        )
        try await store.enqueue(refused, channel: channel)
        try await store.markSending(refused.id)
        try await store.markFailed(refused.id, error: "restricted: demo has no relay")

        // General is marked read so the two channels differ: one caught up,
        // one with unread traffic. Without this every channel looks the same
        // and the badge work is invisible.
        try await store.markRead(channel: channel)
    }

    /// The relay-signed pair that makes a channel a direct message: metadata
    /// carrying the bare `hidden` tag and a placeholder name, plus a roster
    /// that includes the viewer. The viewer matters, because the naming rule
    /// has to drop them and a fixture without them would never prove it does.
    private static func directMessage(
        id: String,
        relayName: String,
        members: [Persona],
        me: PrivateKey,
        relayKey: PrivateKey,
        at seconds: Int64
    ) throws -> [NostrEvent] {
        [
            try NostrEvent.signed(
                kind: .groupMetadata,
                content: #"{"name":"\#(relayName)"}"#,
                tags: [["d", id], ["hidden"]],
                createdAt: date(seconds),
                with: relayKey
            ),
            try NostrEvent.signed(
                kind: .groupMembers,
                content: "",
                tags: [["d", id], ["p", me.publicKey.hex]]
                    + members.map { ["p", $0.key.publicKey.hex] },
                createdAt: date(seconds),
                with: relayKey
            ),
        ]
    }

    private static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private struct Persona {
        let key: PrivateKey
        let name: String
        let about: String

        init(name: String, about: String) throws {
            self.key = try PrivateKey()
            self.name = name
            self.about = about
        }

        func profile(at seconds: Int64) throws -> NostrEvent {
            try NostrEvent.signed(
                kind: .metadata,
                content: #"{"display_name":"\#(name)","about":"\#(about)","lud16":"\#(name.lowercased())@getalby.com"}"#,
                createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
                with: key
            )
        }

        func message(_ text: String, in channel: String, at seconds: Int64) throws -> NostrEvent {
            try NostrEvent.signed(
                kind: .groupChatMessage,
                content: text,
                tags: [["h", channel]],
                createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
                with: key
            )
        }
    }
}
#endif
