import Foundation
@preconcurrency import UserNotifications

@MainActor
final class SaunaLogLocalNotificationManager {
    static let shared = SaunaLogLocalNotificationManager()

    private enum Keys {
        static let hasScheduledTrialExhaustedReminder = "notifications.trialExhaustedReminder.scheduled"
    }

    private let center = UNUserNotificationCenter.current()
    private let reminderIdentifier = "saunalog.trial.exhausted.unlock"
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure() {
        center.delegate = ForegroundNotificationDelegate.shared
    }

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func scheduleUnlockReminderIfNeeded(sessionsCompleted: Int, hasUnlocked: Bool) {
        if hasUnlocked {
            clearUnlockReminder()
            defaults.set(false, forKey: Keys.hasScheduledTrialExhaustedReminder)
            return
        }

        guard sessionsCompleted >= TrialManager.freeSessionLimit else { return }
        guard !defaults.bool(forKey: Keys.hasScheduledTrialExhaustedReminder) else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.string("notification.trial_complete.title")
        content.body = L10n.string("notification.trial_complete.body")
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: reminderIdentifier, content: content, trigger: trigger)

        center.add(request) { error in
            guard error == nil else { return }
            Task { @MainActor in
                SaunaLogLocalNotificationManager.shared.markUnlockReminderScheduled()
            }
        }
    }

    private func markUnlockReminderScheduled() {
        defaults.set(true, forKey: Keys.hasScheduledTrialExhaustedReminder)
    }

    private func clearUnlockReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [reminderIdentifier])
    }
}

private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
