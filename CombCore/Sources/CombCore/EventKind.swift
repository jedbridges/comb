import Foundation

/// A Nostr event kind.
///
/// Modelled as a wrapper around `Int` rather than an enum so unknown kinds
/// survive a decode/encode round trip. Relays evolve faster than clients, and an
/// enum would force us to either drop or fail on kinds we do not recognise yet.
public struct EventKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByIntegerLiteral {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(integerLiteral value: Int) { self.rawValue = value }

    // MARK: - Standard Nostr

    public static let metadata: EventKind = 0            // NIP-01 profile
    public static let textNote: EventKind = 1            // NIP-01
    public static let deletion: EventKind = 5            // NIP-09
    public static let reaction: EventKind = 7            // NIP-25
    /// Reporting a message or a person to whoever moderates the relay. The
    /// standard every Nostr moderation tool already reads, which is why Comb
    /// publishes this rather than inventing a reporting channel of its own.
    public static let report: EventKind = 1984           // NIP-56
    public static let groupChatMessage: EventKind = 9    // NIP-29
    /// NIP-17 private direct messages, outermost first. See `NIP17`.
    public static let directMessage: EventKind = 14      // the rumor, unsigned
    public static let seal: EventKind = 13               // signed by the sender
    public static let giftWrap: EventKind = 1059         // signed by a throwaway key
    public static let clientAuth: EventKind = 22242      // NIP-42 auth response
    public static let httpAuth: EventKind = 27235        // NIP-98 HTTP auth
    public static let blossomAuth: EventKind = 24242     // Blossom BUD-01 media auth
    /// Nostr Wallet Connect (NIP-47), how a wallet is asked to pay.
    ///
    /// 231xx lands in the ephemeral band, which is exactly right and worth
    /// saying out loud: wallet traffic is never stored, so a spend request and
    /// the preimage that answers it do not enter the event log. `StoreSink`
    /// diverts them on the strength of that classification alone.
    ///
    /// Not Buzz extensions. These are standard NIP-47 and go to the wallet's own
    /// relay, never to a community relay.
    public static let nwcInfo: EventKind = 13194         // NIP-47, replaceable
    public static let nwcRequest: EventKind = 23194
    public static let nwcResponse: EventKind = 23195
    public static let nwcNotification: EventKind = 23197

    public static let zapRequest: EventKind = 9734       // NIP-57
    public static let zapReceipt: EventKind = 9735       // NIP-57
    /// NIP-78 arbitrary app data, addressed by its `d` tag. Comb writes one
    /// slot of it, carrying read markers encrypted to the author's own key.
    public static let appData: EventKind = 30078

    // MARK: - NIP-29 relay-based groups (moderation)

    public static let groupAddUser: EventKind = 9000
    public static let groupRemoveUser: EventKind = 9001
    public static let groupEditMetadata: EventKind = 9002
    public static let groupDeleteEvent: EventKind = 9005
    public static let groupCreate: EventKind = 9007
    public static let groupDelete: EventKind = 9008
    public static let groupCreateInvite: EventKind = 9009
    public static let groupJoinRequest: EventKind = 9021
    public static let groupLeaveRequest: EventKind = 9022

    // MARK: - NIP-29 relay-signed group state (addressable)

    public static let groupMetadata: EventKind = 39000
    public static let groupAdmins: EventKind = 39001
    public static let groupMembers: EventKind = 39002
    public static let groupRoles: EventKind = 39003

    // MARK: - Buzz extensions
    //
    // These are not standard NIPs. Comb treats them as progressive enhancement:
    // every one of them must have a graceful fallback so the client stays usable
    // against a plain NIP-29 relay. See `isBuzzExtension`.

    public static let buzzMemberAdd: EventKind = 9030      // NIP-43 relay membership
    public static let buzzMemberRemove: EventKind = 9031
    public static let buzzRoleChange: EventKind = 9032
    public static let buzzWorkspaceProfile: EventKind = 9033
    public static let buzzMembershipList: EventKind = 13534
    public static let buzzPresence: EventKind = 20001      // ephemeral
    public static let buzzTyping: EventKind = 20002        // ephemeral
    public static let buzzRichContent: EventKind = 40002
    public static let buzzEdit: EventKind = 40003

    /// A zap the payer proved themselves, published into the group.
    ///
    /// Exists because standard NIP-57 cannot work on a membership-gated relay.
    /// A kind 9735 is published by the recipient's LNURL host, and that host is
    /// not a member, so it can never reach a hosted Buzz relay: the receipt is
    /// refused and the zap is invisible to everyone including the person paid.
    ///
    /// So the payer publishes the proof instead. The event carries the invoice
    /// and its preimage, and `sha256(preimage) == payment_hash` is settlement,
    /// checkable by anyone offline with no third party involved. Verified by
    /// `Zap.verifyAttestation`.
    ///
    /// A client that does not know this kind sees nothing, which is the
    /// fallback the extension rule requires: zaps still work, they just are not
    /// counted, exactly as they are not counted today.
    public static let buzzZapAttestation: EventKind = 40004
    public static let buzzMemberAdded: EventKind = 44100   // relay-signed notification
    public static let buzzMemberRemoved: EventKind = 44101

    /// Opens a direct message conversation: empty content, one `p` tag per
    /// other participant.
    ///
    /// A command rather than a message. The relay executes it, creates a
    /// NIP-29 group carrying a `hidden` tag, and answers with the new channel
    /// id in the OK message. Nothing is stored under this kind.
    public static let buzzOpenDirectMessage: EventKind = 41010

    /// Kinds that only a Buzz relay will understand. Comb may render these when
    /// present but must never require them.
    public var isBuzzExtension: Bool {
        switch self {
        case .buzzMemberAdd, .buzzMemberRemove, .buzzRoleChange, .buzzWorkspaceProfile,
             .buzzMembershipList, .buzzPresence, .buzzTyping, .buzzRichContent,
             .buzzEdit, .buzzZapAttestation, .buzzMemberAdded, .buzzMemberRemoved,
             .buzzOpenDirectMessage:
            true
        default:
            false
        }
    }

    // MARK: - NIP-01 storage classes

    /// Ephemeral events are never persisted by relays (20000..29999).
    public var isEphemeral: Bool { (20000..<30000).contains(rawValue) }

    /// Replaceable events keep only the newest per pubkey (10000..19999, plus 0 and 3).
    public var isReplaceable: Bool {
        (10000..<20000).contains(rawValue) || rawValue == 0 || rawValue == 3
    }

    /// Addressable events keep the newest per (pubkey, kind, d-tag) (30000..39999).
    public var isAddressable: Bool { (30000..<40000).contains(rawValue) }

    /// Events the relay signs itself rather than accepting from clients. Comb
    /// must not attempt to publish these.
    public var isRelaySigned: Bool {
        switch self {
        case .groupMetadata, .groupAdmins, .groupMembers, .groupRoles,
             .buzzMembershipList, .buzzMemberAdded, .buzzMemberRemoved:
            true
        default:
            false
        }
    }
}

extension EventKind: CustomStringConvertible {
    public var description: String { String(rawValue) }
}
