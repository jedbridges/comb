import BackgroundTasks
import CombStore
import Foundation
import UserNotifications

/// Checks for mentions while the app is closed, and tells you about them.
///
/// This is the honest most Comb can do for notifications on a hosted Buzz
/// relay, whose push gateway will not enrol a third-party client. There is no
/// server pushing to the device, so instead iOS wakes the app on its own
/// schedule (`BGAppRefreshTask`), and during that wake Comb connects, syncs,
/// and posts a *local* notification for anything that named you.
///
/// The cost of having no push is latency, and it is not hidden: iOS decides
/// when these wakes happen, throttles them for apps the user rarely opens, and
/// may skip them entirely on low battery. A mention can arrive minutes to hours
/// after it was sent. The Settings copy says so, because a notification system
/// that quietly under-delivers is worse than one that sets the right
/// expectation.
@MainActor
enum BackgroundRefresh {
    static let taskIdentifier = "dev.jedbridges.comb.refresh"

    /// Registered once at launch, before the app finishes starting, as iOS
    /// requires. The handler runs on a background wake.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    /// Asks iOS to wake us again, no sooner than 15 minutes out. iOS treats
    /// this as a floor and a hint, not a promise; the real interval floats with
    /// how much the user opens the app. Called after every wake and whenever
    /// notifications are switched on.
    static func schedule() {
        guard NotificationSettings.isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Cancels any pending wake, for when the user turns notifications off.
    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// The Settings toggle turning on. Asks the system permission first, and
    /// only commits if it is granted, so the switch can never sit "on" over a
    /// denied permission that would deliver nothing.
    ///
    /// Returns whether it ended up enabled, so the toggle can spring back if
    /// the person declined at the system prompt.
    @discardableResult
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        let granted: Bool
        switch settings.authorizationStatus {
        case .notDetermined:
            granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            granted = false
        default:
            granted = true
        }

        guard granted else {
            NotificationSettings.isEnabled = false
            return false
        }
        NotificationSettings.isEnabled = true
        schedule()
        return true
    }

    /// The toggle turning off: stop future wakes and clear the badge, so the
    /// icon does not keep a stale count after the user opted out.
    static func disable() async {
        NotificationSettings.isEnabled = false
        cancel()
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }

    /// Whether the OS permission is actually granted, for showing the "enable
    /// in iOS Settings" state when the app switch is on but the system's is off.
    static func systemAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Always line up the next wake first: a crash or timeout below must not
        // end the chain of refreshes.
        schedule()

        let work = Task {
            await run()
            task.setTaskCompleted(success: true)
        }

        // iOS grants only a few seconds. If it runs out, cancel the work and
        // report incomplete so the system learns our real cost.
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// One pass over every joined community: connect, sync, notify, update the
    /// badge. Runs in the background wake and, on demand, from a Settings
    /// "check now" the user can use to see it work without waiting for iOS.
    static func run() async {
        guard NotificationSettings.isEnabled else { return }

        var totalUnread = 0
        for community in CommunityRegistry.all() {
            if Task.isCancelled { break }
            totalUnread += await check(community)
        }

        // The badge is the ambient half of the design: it is honest even when
        // stale, and it never interrupts. Set from the total across every
        // community so the number on the icon matches what opening the app
        // would show.
        try? await UNUserNotificationCenter.current().setBadgeCount(totalUnread)
    }

    /// Syncs one community and posts a notification for new mentions in it.
    /// Returns its unread count, for the badge.
    private static func check(_ community: JoinedCommunity) async -> Int {
        guard let key = try? KeychainStore.load(host: community.host) else { return 0 }

        let session: CommunitySession
        do {
            session = try CommunitySession(url: community.relay, key: key)
            // start() runs the bootstrap query and ingests it, which is exactly
            // the sync a wake needs: after it returns, the store holds whatever
            // arrived while the app was closed.
            try await session.start()
        } catch {
            return 0
        }
        defer { Task { await session.stop() } }

        let me = session.me.hex
        let unread = (try? session.store.totalUnread(me: me)) ?? 0

        guard NotificationSettings.shouldNotify(host: community.host) else { return unread }

        let since = NotificationSettings.lastNotified(host: community.host)
        // First run for a community has no watermark: start it at now rather
        // than 1970, or enabling notifications would dump the entire backlog of
        // past mentions as one alarming pile.
        guard since > 0 else {
            NotificationSettings.setLastNotified(nowSeconds(), host: community.host)
            return unread
        }

        let mentions = (try? session.store.mentions(of: me, since: since)) ?? []
        guard let newest = mentions.map(\.createdAt).max() else { return unread }

        await post(mentions: mentions, community: community.displayName)
        NotificationSettings.setLastNotified(newest, host: community.host)
        return unread
    }

    /// One notification per community per wake, coalesced. Background wakes
    /// deliver in batches, so three separate buzzes for three mentions that
    /// arrived together is noise; one that says "3 mentions" is the signal.
    private static func post(mentions: [MentionNotice], community: String) async {
        guard let latest = mentions.last else { return }

        let content = UNMutableNotificationContent()
        if mentions.count == 1 {
            content.title = "\(latest.author) in \(community)"
            content.body = latest.text.isEmpty ? "Mentioned you." : latest.text
        } else {
            content.title = "\(mentions.count) mentions in \(community)"
            // The most recent one, as the preview, so the notification still
            // says something concrete rather than only a count.
            content.body = "\(latest.author): \(latest.text)"
        }
        content.sound = .default
        content.threadIdentifier = "comb.mentions.\(community)"
        content.userInfo = [
            "comb.messageLink": MessageLink.build(
                channelID: latest.channelID,
                messageID: latest.id,
                threadRootID: nil
            )
        ]

        let request = UNNotificationRequest(
            // Coalesced under one id per community per batch, so a later wake
            // replaces rather than stacks if it covers the same window.
            identifier: "comb.mentions.\(community).\(latest.createdAt)",
            content: content,
            trigger: nil   // deliver now
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// `Date().timeIntervalSince1970` is unavailable in some contexts the store
    /// tests run under, but here in the app it is fine; kept in one place so the
    /// watermark's units cannot drift.
    private static func nowSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}
