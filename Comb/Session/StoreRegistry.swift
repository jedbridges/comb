import CombStore
import Foundation

/// One `EventStore` per database file, for the lifetime of the process.
///
/// An `EventStore` wraps a `DatabasePool`, and a pool is not a handle you can
/// hold several of. SQLite's WAL locking coordinates readers and writers through
/// a shared-memory lock table on the assumption that one pool per file per
/// process owns it; open two and they race, and the damage is silent rather
/// than loud.
///
/// Nothing in the app asks for two on purpose. It gets there by asking twice:
/// the activity list opens every joined community's store so it can read across
/// them, and a background wake opens the store for a community whose foreground
/// session already has one. Memoising by path means both callers get what they
/// asked for and the invariant holds.
///
/// Deliberately never evicts. A store's cost is a file handle and a small cache,
/// there are as many of them as communities the person has joined, and an
/// eviction policy here would be a way to hand out a second pool by accident.
final class StoreRegistry: @unchecked Sendable {
    static let shared = StoreRegistry()

    private let lock = NSLock()
    private var stores: [String: EventStore] = [:]

    private init() {}

    /// The store for `path`, opening it with `make` only if this is the first
    /// ask. Callers reach this from the main actor, from a session actor, and
    /// from the detached task the activity list uses, which is why the lock is
    /// doing real work rather than decorating.
    ///
    /// `make` runs under the lock on purpose. Releasing it first would let two
    /// concurrent openers both find nothing and both construct a pool, which is
    /// the exact situation this exists to prevent.
    func store(at path: String, make: () throws -> EventStore) throws -> EventStore {
        lock.lock()
        defer { lock.unlock() }

        if let existing = stores[path] { return existing }
        let store = try make()
        stores[path] = store
        return store
    }

    /// Returns once no open store has a write in flight.
    ///
    /// The one caller is the background wake, on its way to reporting itself
    /// complete. That report is the app telling iOS this is a good moment to
    /// suspend it, and it is only true if nothing is mid-transaction, so this is
    /// the check that makes the claim honest.
    ///
    /// Registry-wide rather than per store because the caller does not know
    /// which stores it touched: a wake walks every joined community, and a
    /// session it gave up on may still be unwinding.
    func settleAll() async {
        for store in openStores() { await store.settle() }
    }

    /// Split out because taking a lock is not allowed in an async context, and
    /// rightly: holding one across a suspension is how you deadlock. This takes
    /// a snapshot and gets out, and the awaiting happens on the snapshot.
    private func openStores() -> [EventStore] {
        lock.lock()
        defer { lock.unlock() }
        return Array(stores.values)
    }
}
