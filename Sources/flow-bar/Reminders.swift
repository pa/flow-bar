import FlowBarCore
import Foundation
import UserNotifications

/// Bridges the pure `[Reminder]` model to the system's local-notification
/// scheduler. Owns the `UNUserNotificationCenter` delegate: it schedules a
/// notification per pending reminder, and routes taps/actions back to `Store`
/// via the `onOpen` / `onSnooze` / `onComplete` callbacks (which `Store` wires
/// to itself). Kept out of `FlowBarCore` so the core stays UI/OS-free and
/// unit-testable.
@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let categoryID = "FLOWBAR_REMINDER"
    static let snoozeAction = "SNOOZE_1H"
    static let completeAction = "COMPLETE"

    /// Routing callbacks, set by `Store`; always invoked on the main actor.
    var onOpen: ((UUID) -> Void)?
    var onSnooze: ((UUID) -> Void)?
    var onComplete: ((UUID) -> Void)?
    /// Reports the current authorization state (true = denied/unavailable) so
    /// the UI can show a "turn on notifications" hint.
    var onAuthDenied: ((Bool) -> Void)?

    /// Local notifications require a bundled, signed app. A bare `swift run`
    /// executable has no bundle id and `UNUserNotificationCenter.current()`
    /// would trap — so the scheduler no-ops there (the UI/persistence still
    /// work; real notifications only fire from `flow-bar.app`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    /// Register the delegate + the Snooze/Complete notification actions.
    func configure() {
        guard let center else { return }
        center.delegate = self
        let snooze = UNNotificationAction(
            identifier: Self.snoozeAction, title: "Snooze 1 hour", options: [])
        let complete = UNNotificationAction(
            identifier: Self.completeAction, title: "Mark complete", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [snooze, complete],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    /// Ask for alert/sound permission the first time; report denial otherwise.
    ///
    /// `nonisolated` on purpose: `getNotificationSettings` invokes its handler
    /// on a background queue, so this closure must NOT inherit the type's
    /// @MainActor isolation (that would trip a runtime executor assertion and
    /// crash). We only hop back to the main actor to touch `onAuthDenied`.
    nonisolated func requestAuthorizationIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            CLI.log("notifications: no bundle id — scheduler disabled (bare `swift run`?)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            CLI.log("notifications: bundle=\(bundleID) path=\(Bundle.main.bundlePath) "
                           + "status=\(Self.describe(status))")
            if status == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    // The error used to be discarded, which is why a failure to
                    // register was completely silent: the app simply never
                    // appeared in System Settings > Notifications and there was
                    // nothing anywhere to explain it.
                    if let error {
                        CLI.log("notifications: requestAuthorization FAILED — \(error)")
                    } else {
                        CLI.log("notifications: requestAuthorization granted=\(granted)")
                    }
                    Task { @MainActor in self.onAuthDenied?(!granted) }
                }
            } else {
                let denied = (status == .denied)
                Task { @MainActor in self.onAuthDenied?(denied) }
            }
        }
    }

    nonisolated private static func describe(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .provisional:   return "provisional"
        case .ephemeral:     return "ephemeral"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    /// Replace all scheduled notifications with one per pending (incomplete,
    /// future) reminder. Idempotent — safe to call on every change and launch.
    func reconcile(_ reminders: [Reminder]) {
        guard let center else { return }
        center.removeAllPendingNotificationRequests()
        let now = Date()
        var scheduled = 0
        for r in reminders where !r.isCompleted && r.fireDate > now {
            let content = UNMutableNotificationContent()
            content.title = r.title.isEmpty ? "Reminder" : r.title
            if let note = r.note, !note.isEmpty {
                content.body = note
            } else if !r.tasks.isEmpty {
                let names = r.tasks.map { $0.name }
                content.body = names.count == 1
                    ? "Task: \(names[0])"
                    : "Tasks: \(names.joined(separator: ", "))"
            }
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["reminderID": r.id.uuidString]
            // The notification's icon is the app icon (compiled from the
            // asset-catalog AppIcon in the release build) — no attachment.

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: r.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(
                identifier: r.id.uuidString, content: content, trigger: trigger)
            // Capture the id, not the Reminder: Reminder isn't Sendable and
            // this completion runs off the main actor.
            let rid = r.id
            center.add(request) { error in
                if let error {
                    CLI.log("notifications: add failed for \(rid) — \(error)")
                }
            }
            scheduled += 1
        }
        CLI.log("notifications: reconcile scheduled \(scheduled) of \(reminders.count) reminder(s)")
    }

    // MARK: - UNUserNotificationCenterDelegate (called off the main actor)

    /// Show the banner even when flow-bar is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A tap (or a Snooze/Complete action) on a delivered notification. We only
    /// pass Sendable values (the reminder id string + action id) across to the
    /// main actor; the completion handler is invoked synchronously first.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let idString = response.notification.request.content.userInfo["reminderID"] as? String
        completionHandler()
        guard let idString, let id = UUID(uuidString: idString) else { return }
        Task { @MainActor in
            switch action {
            case Self.snoozeAction:   self.onSnooze?(id)
            case Self.completeAction: self.onComplete?(id)
            default:                  self.onOpen?(id)   // includes the default tap
            }
        }
    }
}
