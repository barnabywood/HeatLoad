import Foundation
@preconcurrency import UserNotifications

@MainActor
final class SaunaLogLocalNotificationManager {
    static let shared = SaunaLogLocalNotificationManager()

    static let routeNotificationName = Notification.Name("SaunaLogLocalNotificationRoute")

    enum Route: String {
        case insights
    }

    private enum Keys {
        static let hasScheduledTrialExhaustedReminder = "notifications.trialExhaustedReminder.scheduled"
        static let hasScheduledWatchInstallReminder = "notifications.watchInstallReminder.scheduled"
        static let monthlyInsightsEnabled = "notifications.monthlyInsights.enabled"
        static let route = "saunaLogRoute"
    }

    static let monthlyInsightsEnabledKey = Keys.monthlyInsightsEnabled

    static var areMonthlyInsightsEnabledByDefault: Bool {
        UserDefaults.standard.object(forKey: monthlyInsightsEnabledKey) as? Bool ?? true
    }

    private let center = UNUserNotificationCenter.current()
    private let reminderIdentifier = "saunalog.trial.exhausted.unlock"
    private let watchInstallReminderIdentifier = "saunalog.watch.install.reminder"
    private let monthlyInsightsIdentifierPrefix = "saunalog.monthly.insights"
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

    func scheduleWatchInstallReminderIfNeeded(isPaired: Bool, isWatchAppInstalled: Bool) {
        if !isPaired || isWatchAppInstalled {
            clearWatchInstallReminder()
            defaults.set(false, forKey: Keys.hasScheduledWatchInstallReminder)
            return
        }

        guard !defaults.bool(forKey: Keys.hasScheduledWatchInstallReminder) else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.string("notification.watch_missing.title")
        content.body = L10n.string("notification.watch_missing.body")
        content.sound = .default
        content.interruptionLevel = .active

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(identifier: watchInstallReminderIdentifier, content: content, trigger: trigger)

        center.add(request) { error in
            guard error == nil else { return }
            Task { @MainActor in
                SaunaLogLocalNotificationManager.shared.markWatchInstallReminderScheduled()
            }
        }
    }


    func scheduleMonthlyInsightsNotifications() {
        scheduleMonthlyInsightsNotifications(isEnabled: Self.areMonthlyInsightsEnabledByDefault)
    }

    func scheduleMonthlyInsightsNotifications(isEnabled: Bool) {
        guard isEnabled else {
            clearMonthlyInsightsNotifications()
            return
        }

        center.getPendingNotificationRequests { [monthlyInsightsIdentifierPrefix] requests in
            let existingIdentifiers = Set(
                requests
                    .map(\.identifier)
                    .filter { $0.hasPrefix(monthlyInsightsIdentifierPrefix) }
            )

            let scheduled = Self.monthEndNotificationDates(from: Date(), count: 12)
            for date in scheduled {
                let identifier = Self.monthlyInsightsIdentifier(for: date, prefix: monthlyInsightsIdentifierPrefix)
                guard !existingIdentifiers.contains(identifier) else { continue }

                let content = UNMutableNotificationContent()
                content.title = L10n.string("notification.monthly_insights.title")
                content.body = L10n.string("notification.monthly_insights.body")
                content.sound = .default
                content.interruptionLevel = .active
                content.userInfo = [Keys.route: Route.insights.rawValue]

                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private func markUnlockReminderScheduled() {
        defaults.set(true, forKey: Keys.hasScheduledTrialExhaustedReminder)
    }

    private func markWatchInstallReminderScheduled() {
        defaults.set(true, forKey: Keys.hasScheduledWatchInstallReminder)
    }

    private func clearUnlockReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [reminderIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [reminderIdentifier])
    }

    private func clearWatchInstallReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [watchInstallReminderIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [watchInstallReminderIdentifier])
    }

    private func clearMonthlyInsightsNotifications() {
        center.getPendingNotificationRequests { [monthlyInsightsIdentifierPrefix] requests in
            let identifiers = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(monthlyInsightsIdentifierPrefix) }
            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }

        center.getDeliveredNotifications { [monthlyInsightsIdentifierPrefix] notifications in
            let identifiers = notifications
                .map { $0.request.identifier }
                .filter { $0.hasPrefix(monthlyInsightsIdentifierPrefix) }
            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    nonisolated private static func monthEndNotificationDates(from now: Date, count: Int) -> [Date] {
        let calendar = Calendar.current
        let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        var dates: [Date] = []
        var seenMonthKeys = Set<String>()
        var offset = 0

        while dates.count < count, offset < count + 3 {
            defer { offset += 1 }

            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: currentMonthStart),
                  let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonthStart),
                  let notificationDate = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: lastDay) else {
                continue
            }
            guard notificationDate > now else { continue }

            let key = monthlyInsightsIdentifier(for: notificationDate, prefix: "month")
            guard !seenMonthKeys.contains(key) else { continue }
            seenMonthKeys.insert(key)
            dates.append(notificationDate)
        }

        return dates
    }

    nonisolated private static func monthlyInsightsIdentifier(for date: Date, prefix: String) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(prefix).\(components.year ?? 0).\(components.month ?? 0)"
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let routeValue = response.notification.request.content.userInfo["saunaLogRoute"] as? String,
           let route = SaunaLogLocalNotificationManager.Route(rawValue: routeValue) {
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: SaunaLogLocalNotificationManager.routeNotificationName,
                    object: route
                )
            }
        }
        completionHandler()
    }
}
