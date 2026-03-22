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
    private let immediateNotificationIdentifier = "awaken.phoneAlarm.immediate"
    private let categoryIdentifier = "awaken.phoneAlarmCategory"
    private let stopActionIdentifier = "awaken.phoneAlarm.stop"
    private let snoozeActionIdentifier = "awaken.phoneAlarm.snooze"

    private static let customSoundFilename = "awaken-alarm.wav"

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

    // MARK: - Custom Sound

    /// Save a WAV file to Library/Sounds so it can be used as a notification sound.
    /// The WAV must be ≤30 seconds. Returns the filename on success.
    @discardableResult
    func saveCustomAlarmSound(wavData: Data) -> String? {
        guard let libDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let soundsDir = libDir.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        let fileURL = soundsDir.appendingPathComponent(Self.customSoundFilename)
        do {
            try wavData.write(to: fileURL, options: .atomic)
            return Self.customSoundFilename
        } catch {
            print("Failed to save alarm sound: \(error)")
            return nil
        }
    }

    private var notificationSound: UNNotificationSound {
        let libDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        let soundFile = libDir?
            .appendingPathComponent("Sounds", isDirectory: true)
            .appendingPathComponent(Self.customSoundFilename)
        if let soundFile, FileManager.default.fileExists(atPath: soundFile.path) {
            return UNNotificationSound(named: UNNotificationSoundName(Self.customSoundFilename))
        }
        return .default
    }

    // MARK: - Scheduled Alarm

    func schedulePhoneAlarm(for fireDate: Date, displayTime: String?) {
        Task {
            await requestAuthorizationIfNeeded()
            await cancelPhoneAlarm()

            let content = UNMutableNotificationContent()
            content.title = "AWAKEN Alarm"
            content.body = displayTime.map { "Alarm for \($0)" } ?? "Your alarm is going off."
            content.sound = notificationSound
            content.categoryIdentifier = categoryIdentifier
            content.interruptionLevel = .timeSensitive

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

    // MARK: - Immediate Alarm (BLE alarm-state fired while backgrounded)

    func fireImmediateAlarmNotification() {
        Task {
            await requestAuthorizationIfNeeded()

            let content = UNMutableNotificationContent()
            content.title = "AWAKEN Alarm"
            content.body = "Wake up! Your alarm is going off."
            content.sound = notificationSound
            content.categoryIdentifier = categoryIdentifier
            content.interruptionLevel = .timeSensitive

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: immediateNotificationIdentifier,
                content: content,
                trigger: trigger
            )

            try? await center.add(request)
        }
    }

    func cancelPhoneAlarm() async {
        center.removePendingNotificationRequests(withIdentifiers: [
            notificationIdentifier,
            immediateNotificationIdentifier
        ])
        center.removeDeliveredNotifications(withIdentifiers: [
            notificationIdentifier,
            immediateNotificationIdentifier
        ])
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
