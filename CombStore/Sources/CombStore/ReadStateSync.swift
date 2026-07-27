import CombCore
import Foundation
import GRDB

/// Where one channel's read line sits, and when this device last moved it.
///
/// The pair is what makes two devices reconcilable. The marker alone cannot
/// settle a disagreement, because "mark unread" moves it backwards deliberately
/// and so the larger value is sometimes the older decision.
public struct ReadMarker: Sendable, Equatable, Hashable, Codable {
    public let channelID: String
    /// The newest message considered read, in Unix seconds.
    public let lastReadAt: Int64
    /// When a device last said so, in Unix seconds.
    public let updatedAt: Int64

    public init(channelID: String, lastReadAt: Int64, updatedAt: Int64) {
        self.channelID = channelID
        self.lastReadAt = lastReadAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        // Short keys: this rides inside an encrypted payload that a relay
        // stores forever, and there is no reason for it to be bigger than the
        // information in it.
        case channelID = "c"
        case lastReadAt = "r"
        case updatedAt = "u"
    }
}

/// The payload of a kind 30078 read-state event, before encryption.
public struct ReadStatePayload: Sendable, Equatable, Codable {
    /// Bumped if the shape ever changes. A reader that does not recognise the
    /// version ignores the event rather than guessing at it, which is the only
    /// safe thing to do with state that decides what you have already seen.
    public static let currentVersion = 1

    public let version: Int
    public let markers: [ReadMarker]

    public init(version: Int = ReadStatePayload.currentVersion, markers: [ReadMarker]) {
        self.version = version
        self.markers = markers
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case markers = "m"
    }
}

public enum ReadStateSync {
    /// The `d` tag identifying this application's slot in kind 30078.
    ///
    /// NIP-78 addresses app data by (kind, pubkey, `d`), and 30078 is a shared
    /// namespace every client writes into. A generic `d` would have Comb
    /// overwrite some other client's unrelated state, and be overwritten back.
    public static let dTag = "comb.read-state"

    /// Reconciles two sets of markers, newest decision winning per channel.
    ///
    /// Last-writer-wins rather than furthest-marker-wins, so marking something
    /// unread on a phone survives the laptop that read it an hour earlier.
    /// A tie on `updatedAt` falls back to the larger marker: two devices
    /// writing in the same second is a coin toss, and the tie has to break the
    /// same way on both or they will disagree forever.
    ///
    /// Pure and total: it never consults a clock and never drops a channel that
    /// appears on only one side.
    public static func merge(local: [ReadMarker], remote: [ReadMarker]) -> [ReadMarker] {
        var byChannel: [String: ReadMarker] = [:]

        for marker in local + remote {
            guard let existing = byChannel[marker.channelID] else {
                byChannel[marker.channelID] = marker
                continue
            }
            byChannel[marker.channelID] = wins(existing, marker) ? existing : marker
        }

        return byChannel.values.sorted { $0.channelID < $1.channelID }
    }

    private static func wins(_ a: ReadMarker, _ b: ReadMarker) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.lastReadAt >= b.lastReadAt
    }
}

public extension EventStore {
    /// Every read marker this device holds, for publishing.
    nonisolated func readMarkers() throws -> [ReadMarker] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT channel_id, last_read_at, updated_at FROM read_state
                ORDER BY channel_id
                """)
            .map {
                ReadMarker(
                    channelID: $0["channel_id"],
                    lastReadAt: $0["last_read_at"],
                    updatedAt: $0["updated_at"] ?? 0
                )
            }
        }
    }

    /// Folds markers from another device into this one's read state.
    ///
    /// Returns whether anything actually changed, so a caller can avoid
    /// republishing state it just received and bouncing it back and forth.
    @discardableResult
    func mergeReadMarkers(_ remote: [ReadMarker]) throws -> Bool {
        guard !remote.isEmpty else { return false }

        return try writer.write { db in
            var changed = false

            for marker in remote {
                let current = try Row.fetchOne(db, sql: """
                    SELECT last_read_at, updated_at FROM read_state WHERE channel_id = ?
                    """, arguments: [marker.channelID])

                if let current {
                    let mine = ReadMarker(
                        channelID: marker.channelID,
                        lastReadAt: current["last_read_at"],
                        updatedAt: current["updated_at"] ?? 0
                    )
                    // One channel at a time through the same rule the whole-set
                    // merge uses, so a row-by-row update and a full reconcile
                    // can never reach different answers.
                    guard ReadStateSync.merge(local: [mine], remote: [marker]) != [mine] else {
                        continue
                    }
                }

                try db.execute(sql: """
                    INSERT INTO read_state (channel_id, last_read_at, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(channel_id) DO UPDATE SET
                        last_read_at = excluded.last_read_at,
                        updated_at = excluded.updated_at
                    """, arguments: [marker.channelID, marker.lastReadAt, marker.updatedAt])
                changed = true
            }

            return changed
        }
    }
}
