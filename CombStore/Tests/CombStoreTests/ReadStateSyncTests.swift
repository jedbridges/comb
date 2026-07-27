import CombCore
import Foundation
import Testing
@testable import CombStore

@Suite("Read state sync")
struct ReadStateSyncTests {
    private func marker(_ id: String, read: Int64, updated: Int64) -> ReadMarker {
        ReadMarker(channelID: id, lastReadAt: read, updatedAt: updated)
    }

    @Test("the newer decision wins, even when it moves the marker backwards")
    func lastWriterWins() {
        // The case max-wins gets wrong: a phone marked this unread after the
        // laptop had read it. The phone spoke last, so the phone is right.
        let laptop = marker("room-1", read: 5000, updated: 100)
        let phone = marker("room-1", read: 3000, updated: 200)

        #expect(ReadStateSync.merge(local: [laptop], remote: [phone]) == [phone])
        #expect(ReadStateSync.merge(local: [phone], remote: [laptop]) == [phone])
    }

    @Test("a stale remote cannot undo a newer local read")
    func staleRemoteLoses() {
        let local = marker("room-1", read: 5000, updated: 200)
        let remote = marker("room-1", read: 9000, updated: 100)
        #expect(ReadStateSync.merge(local: [local], remote: [remote]) == [local])
    }

    @Test("a tie breaks the same way whichever side it is read from")
    func tieIsSymmetric() {
        // Two devices writing in the same second is a coin toss, but it has to
        // land the same way on both or they never converge.
        let a = marker("room-1", read: 5000, updated: 100)
        let b = marker("room-1", read: 3000, updated: 100)

        #expect(ReadStateSync.merge(local: [a], remote: [b]) == [a])
        #expect(ReadStateSync.merge(local: [b], remote: [a]) == [a])
    }

    @Test("channels on only one side survive")
    func unionsChannels() {
        let mine = marker("room-1", read: 5000, updated: 100)
        let theirs = marker("room-2", read: 7000, updated: 100)

        let merged = ReadStateSync.merge(local: [mine], remote: [theirs])
        #expect(merged == [mine, theirs])
    }

    @Test("merging is idempotent")
    func idempotent() {
        let markers = [
            marker("room-1", read: 5000, updated: 100),
            marker("room-2", read: 7000, updated: 300),
        ]
        let once = ReadStateSync.merge(local: markers, remote: markers)
        #expect(once == markers)
        #expect(ReadStateSync.merge(local: once, remote: markers) == markers)
    }

    @Test("the payload survives a round trip")
    func codesRoundTrip() throws {
        let payload = ReadStatePayload(markers: [
            marker("room-1", read: 5000, updated: 100),
        ])
        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode(ReadStatePayload.self, from: data)

        #expect(back == payload)
        #expect(back.version == ReadStatePayload.currentVersion)
    }

    @Test("reading a channel records when the marker moved")
    func markReadStampsTime() async throws {
        let store = try EventStore()
        let author = try Fixture()
        _ = try await store.ingest([
            try author.event(.groupMetadata, "{}", tags: [["d", "room-1"]], at: 900),
            try author.message("hello", at: 1000),
        ])

        try await store.markRead(channel: "room-1", at: 5555)

        let markers = try store.readMarkers()
        #expect(markers == [ReadMarker(channelID: "room-1", lastReadAt: 1000, updatedAt: 5555)])
    }

    @Test("a newer remote marker is adopted")
    func adoptsNewerRemote() async throws {
        let store = try EventStore()
        let author = try Fixture()
        _ = try await store.ingest([
            try author.event(.groupMetadata, "{}", tags: [["d", "room-1"]], at: 900),
            try author.message("hello", at: 1000),
        ])
        try await store.markRead(channel: "room-1", at: 100)

        let changed = try await store.mergeReadMarkers([
            marker("room-1", read: 4000, updated: 200),
        ])

        #expect(changed)
        #expect(try store.readMarkers().first?.lastReadAt == 4000)
        // And the channel is read now, which is the point of syncing at all.
        #expect(try store.channelSummaries().first?.unreadCount == 0)
    }

    @Test("an older remote marker is ignored and reports no change")
    func ignoresOlderRemote() async throws {
        let store = try EventStore()
        let author = try Fixture()
        _ = try await store.ingest([
            try author.event(.groupMetadata, "{}", tags: [["d", "room-1"]], at: 900),
            try author.message("hello", at: 1000),
        ])
        try await store.markRead(channel: "room-1", at: 5000)

        // No change reported is what stops two devices bouncing the same state
        // back and forth forever.
        let changed = try await store.mergeReadMarkers([
            marker("room-1", read: 9999, updated: 100),
        ])

        #expect(!changed)
        #expect(try store.readMarkers().first?.lastReadAt == 1000)
    }

    @Test("a remote unread marker makes the channel unread again")
    func remoteUnreadPropagates() async throws {
        let store = try EventStore()
        let author = try Fixture()
        _ = try await store.ingest([
            try author.event(.groupMetadata, "{}", tags: [["d", "room-1"]], at: 900),
            try author.message("hello", at: 1000),
        ])
        try await store.markRead(channel: "room-1", at: 100)
        #expect(try store.channelSummaries().first?.unreadCount == 0)

        try await store.mergeReadMarkers([marker("room-1", read: 999, updated: 200)])
        #expect(try store.channelSummaries().first?.unreadCount == 1)
    }
}
