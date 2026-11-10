import Foundation
import HermesLensCore
import UserNotifications

actor NotificationService {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func schedule(_ reminder: ReminderRecord) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.note.isEmpty ? "Reminder" : reminder.note
        content.sound = .default
        content.userInfo = ["reminderID": reminder.id.uuidString]

        let interval = max(reminder.dueAt.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: reminder.notificationIdentifier,
            content: content,
            trigger: trigger
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    func cancel(_ reminder: ReminderRecord) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [reminder.notificationIdentifier]
        )
    }
}
