import Foundation
import UserNotifications

extension Notification.Name {
    static let awakenAlarmNotificationTriggered = Notification.Name("awakenAlarmNotificationTriggered")
    static let awakenAlarmNotificationStopRequested = Notification.Name("awakenAlarmNotificationStopRequested")
    static let awakenAlarmNotificationSnoozeRequested = Notification.Name("awakenAlarmNotificationSnoozeRequested")
}

final class AlarmNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlarmNotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let notificationIdentifier = "awaken.phoneAlarm"
    private let categoryIdentifier = "awaken.phoneAlarmCategory"
    private let stopActionIdentifier = "awaken.phoneAlarm.stop"
    private let snoozeActionIdentifier = "awaken.phoneAlarm.snooze"

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self
        let stopAction = UNNotificationAction(
            identifier: stopActionIdentifier,
            title: "Shut Off",
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: snoozeActionIdentifier,
            title: "Snooze",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [snoozeAction, stopAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    func schedulePhoneAlarm(for fireDate: Date, displayTime: String?) {
        Task {
            await requestAuthorizationIfNeeded()
            await cancelPhoneAlarm()

            let content = UNMutableNotificationContent()
            content.title = "Awaken Alarm"
            content.body = displayTime.map { "Alarm for \($0)" } ?? "Your alarm is going off."
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: notificationIdentifier,
                content: content,
                trigger: trigger
            )

            try? await center.add(request)
        }
    }

    func cancelPhoneAlarm() async {
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
    }

    private func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        NotificationCenter.default.post(name: .awakenAlarmNotificationTriggered, object: nil)
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case stopActionIdentifier:
            NotificationCenter.default.post(name: .awakenAlarmNotificationStopRequested, object: nil)
        case snoozeActionIdentifier:
            NotificationCenter.default.post(name: .awakenAlarmNotificationSnoozeRequested, object: nil)
        default:
            NotificationCenter.default.post(name: .awakenAlarmNotificationTriggered, object: nil)
        }
    }
}
