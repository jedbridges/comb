import CombStore
import Foundation
import UserNotifications

/// "Remind me later" for a message.
///
/// This is the one notification-shaped feature that works despite hosted
/// Buzz's push being closed to third-party clients: it is a purely local
/// notification, scheduled on the device and delivered by the device, with no
/// relay and no push gateway involved. Nothing about the message leaves the
/// phone.
///
/// It is not a substitute for real push. It cannot fire for a message that has
/// not arrived yet, and it only reminds the one person who set it. What it does
/// is let someone triage: see a message they cannot deal with now, and be
/// nudged back to it on their own schedule.
@MainActor
enum Reminders {
    /// The offsets offered in the menu. Kept short: a reminder people have to
    /// configure is a reminder people do not set.
    enum When: String, CaseIterable, Identifiable {
        case twentyMinutes
        case oneHour
        case threeHours
        case tomorrow

        var id: String { rawValue }

        var label: String {
            switch self {
            case .twentyMinutes: "In 20 minutes"
            case .oneHour: "In 1 hour"
            case .threeHours: "In 3 hours"
            case .tomorrow: "Tomorrow morning"
            }
        }

        /// When the notification should fire, from now.
        func fireDate(from now: Date, calendar: Calendar) -> Date {
            switch self {
            case .twentyMinutes: now.addingTimeInterval(20 * 60)
            case .oneHour: now.addingTimeInterval(60 * 60)
            case .threeHours: now.addingTimeInterval(3 * 60 * 60)
            case .tomorrow:
                // 9am the next day, not "24 hours from now": a reminder set at
                // 11pm should land in the morning, not the following night.
                calendar.nextDate(
                    after: now,
                    matching: DateComponents(hour: 9),
                    matchingPolicy: .nextTime
                ) ?? now.addingTimeInterval(12 * 60 * 60)
            }
        }
    }

    /// Requests permission if needed and schedules the reminder.
    ///
    /// Returns whether it was scheduled, so the caller can tell the person if
    /// permission was refused rather than leaving them believing a reminder is
    /// coming that never will.
    static func schedule(
        message: TimelineRow,
        channelName: String,
        deepLink: String,
        when: When,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return false }
        case .denied:
            return false
        default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "\(message.displayName) in \(channelName)"
        // The body doubles as the reminder of what the message was, so a
        // preview of it beats a generic "you asked to be reminded".
        let preview = message.displayContent
        content.body = preview.isEmpty ? "Tap to open the message." : String(preview.prefix(140))
        content.sound = .default
        // Carried so a future tap-handler can route to the exact message. The
        // routing is not built yet; the link is stored now so setting it later
        // needs no change here.
        content.userInfo = ["comb.messageLink": deepLink]

        let interval = when.fireDate(from: now, calendar: calendar).timeIntervalSince(now)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, interval),
            repeats: false
        )

        let request = UNNotificationRequest(
            // Message id as the identifier, so setting a second reminder for
            // the same message replaces the first rather than stacking.
            identifier: "comb.reminder.\(message.id)",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
