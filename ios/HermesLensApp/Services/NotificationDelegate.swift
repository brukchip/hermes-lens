import UIKit
import UserNotifications

extension Notification.Name {
    /// A reminder notification was tapped; `object` is the reminder's UUID.
    static let lunaReminderOpened = Notification.Name("lunaReminderOpened")
}

/// Shows reminder notifications in the foreground and opens the reminder on tap.
/// Reminders are local notifications; the app registers for no remote push.
final class NotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let reminder = (userInfo["reminderID"] as? String).flatMap(UUID.init(uuidString:)) {
            NotificationCenter.default.post(name: .lunaReminderOpened, object: reminder)
        }
        completionHandler()
    }
}
