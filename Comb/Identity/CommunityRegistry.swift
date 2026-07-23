import Foundation

/// The communities this device has joined. Names and URLs only; keys live in
/// the Keychain, and everything else is derivable from the relay.
struct JoinedCommunity: Codable, Equatable, Identifiable {
    let host: String
    let relay: URL
    var name: String?
    let joinedAt: Date

    var id: String { host }

    /// A human name for the community.
    ///
    /// Buzz relays cannot supply this: every one of them returns the same
    /// hardcoded NIP-11 name, deliberately, so that nobody can enumerate
    /// communities. Buzz's own desktop client asks the user to type a nickname
    /// for exactly this reason. Comb derives a sensible default from the
    /// subdomain instead, so `designers.communities.buzz.xyz` reads as
    /// "designers", and lets an explicit name win when one is known.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return Self.derivedName(from: host)
    }

    static func derivedName(from host: String) -> String {
        let parts = host.split(separator: ".")
        // A bare or two-label host has no subdomain to borrow.
        guard parts.count > 2, let first = parts.first, first != "www" else {
            return host
        }
        return String(first)
    }
}

enum CommunityRegistry {
    private static let key = "comb.communities"

    static func all() -> [JoinedCommunity] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([JoinedCommunity].self, from: data)) ?? []
    }

    static func add(_ community: JoinedCommunity) {
        var communities = all().filter { $0.host != community.host }
        communities.append(community)
        save(communities)
    }

    /// Removes the registry entry only. The Keychain key deliberately survives:
    /// re-joining the same community reuses it, so leaving and returning keeps
    /// the same identity instead of minting a stranger.
    static func remove(host: String) {
        save(all().filter { $0.host != host })
    }

    private static func save(_ communities: [JoinedCommunity]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(communities), forKey: key)
    }
}
