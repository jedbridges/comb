import CombCore
import CombStore
import Foundation
import Observation

/// The app's spine: which community is open, and how we got there.
@MainActor
@Observable
final class AppModel {
    enum Stage {
        /// Deciding whether a stored community can open silently.
        case launching
        /// No community yet, or the user stepped out.
        case welcome
        /// Connected and reading.
        case active(CommunitySession)
    }

    private(set) var stage: Stage = .launching
    /// A launch that could not auto-connect explains itself on the welcome
    /// screen instead of dead-ending.
    private(set) var launchNotice: String?

    /// The moment the app becomes real for a first-time user: a stored
    /// community opens straight into channels, no ceremony.
    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            await openDemo()
            return
        }
        #endif

        guard let community = CommunityRegistry.all().first else {
            stage = .welcome
            return
        }
        guard let key = try? KeychainStore.load(host: community.host) else {
            // Registry without a key means custody was lost, which should be
            // impossible; falling to welcome beats crashing on a ghost entry.
            stage = .welcome
            return
        }

        do {
            let session = try CommunitySession(url: community.relay, key: key)
            try await session.start()
            stage = .active(session)
        } catch {
            // Offline is the common cause. The store is on disk, so a session
            // that fails to connect could still read; that offline-first launch
            // is Phase 8 polish. For now the welcome screen says what happened.
            launchNotice = "Could not reach \(community.displayName). Check the connection and try again."
            stage = .welcome
        }
    }

    /// Hands the stage to a session an onboarding flow already opened.
    func adopt(_ session: CommunitySession) {
        launchNotice = nil
        stage = .active(session)
    }

    /// Every community this device has joined, most recent first.
    var communities: [JoinedCommunity] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            return [
                JoinedCommunity(
                    host: "demo.local", relay: URL(string: "wss://demo.local")!,
                    name: nil, joinedAt: Date()
                ),
                JoinedCommunity(
                    host: "designers.communities.buzz.xyz",
                    relay: URL(string: "wss://designers.communities.buzz.xyz")!,
                    name: nil, joinedAt: Date().addingTimeInterval(-86400)
                ),
            ]
        }
        #endif
        return CommunityRegistry.all().sorted { $0.joinedAt > $1.joinedAt }
    }

    /// Opens a different community, closing the current one first so two
    /// sessions never hold sockets at once.
    func openCommunity(_ community: JoinedCommunity) async {
        guard let key = try? KeychainStore.load(host: community.host) else {
            launchNotice = "No account stored for \(community.displayName)."
            return
        }
        if case .active(let current) = stage {
            guard current.relayURL != community.relay else { return }
            await current.stop()
        }

        stage = .launching
        do {
            let session = try CommunitySession(url: community.relay, key: key)
            try await session.start()
            stage = .active(session)
        } catch {
            launchNotice = "Could not reach \(community.displayName)."
            stage = .welcome
        }
    }

    /// Leaves the current community open and sends the user to onboarding to
    /// add another.
    func addCommunity() async {
        if case .active(let session) = stage { await session.stop() }
        launchNotice = nil
        stage = .welcome
    }

    /// Steps out of the community. The registry entry and key survive, so the
    /// next launch reconnects; this is the door, not the shredder.
    func signOut() async {
        if case .active(let session) = stage {
            await session.stop()
        }
        stage = .welcome
    }

    /// Forgets the community on this device. The Keychain key is deliberately
    /// kept even here: without a backup flow, deleting it would destroy an
    /// identity irrecoverably, and rejoining by invite quietly reuses it.
    func forgetCommunity() async {
        if case .active(let session) = stage {
            CommunityRegistry.remove(host: session.relayURL.host ?? "")
            await session.stop()
        }
        stage = .welcome
    }

    #if DEBUG
    /// Lets automation drive screens with no taps:
    /// simctl launch ... --demo [--open-first-channel]
    enum LaunchFlags {
        static var opensFirstChannel: Bool {
            ProcessInfo.processInfo.arguments.contains("--open-first-channel")
        }
    }

    func openDemo() async {
        do {
            let key = try PrivateKey()
            let session = try CommunitySession(
                url: URL(string: "wss://demo.local")!,
                key: key,
                store: try EventStore()   // in-memory: fresh every launch
            )
            try await DemoSeed.seed(into: session.store, as: key)
            stage = .active(session)
        } catch {
            stage = .welcome
        }
    }
    #endif
}
