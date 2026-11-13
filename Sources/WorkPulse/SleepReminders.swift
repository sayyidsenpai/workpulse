import Foundation
import UserNotifications
import WorkPulseCore

private let sleepCategory = "SLEEP_REMINDER"
private let snoozeAction = "SNOOZE"
private let dismissAction = "DISMISS"
private let snoozeID = "sleep-snooze"
private let weeklyIDs = (1...7).map { "sleep-\($0)" }
private let workEndCategory = "WORK_HOURS_ENDED"
private let endWorkAction = "END_WORK"
private let workEndID = "work-hours-ended"

/// Sleep reminders as native, repeating local notifications. macOS keeps the schedule, so
/// reminders fire even when WorkPulse is not running. This module only ever posts
/// notifications: it never touches tracking, sessions or other applications. The one exception
/// is the "End work" button of the end-of-work-hours notice, which calls `onEndWork`.
@MainActor
final class SleepReminders: NSObject, UNUserNotificationCenterDelegate {
    /// UserNotifications needs a real app bundle (not a bare `swift run` binary).
    let available = Bundle.main.bundleIdentifier != nil
    private var center: UNUserNotificationCenter { .current() }
    /// The user pressed "End work" in the end-of-work-hours notification.
    var onEndWork: (() -> Void)?

    func configure() {
        guard available else { return }
        center.delegate = self
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze")
        let dismiss = UNNotificationAction(identifier: dismissAction, title: "Dismiss")
        let endWork = UNNotificationAction(identifier: endWorkAction, title: "End work")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: sleepCategory, actions: [snooze, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: workEndCategory, actions: [endWork], intentIdentifiers: []),
        ])
    }

    /// One notice when work hours end while the user still works. WorkPulse plays its own chime.
    func workHoursEnded(at time: String) async {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = time.isEmpty ? "Work hours ended" : "Work hours ended at \(time)"
        content.body = "WorkPulse still counts your work."
        content.categoryIdentifier = workEndCategory
        try? await center.add(UNNotificationRequest(identifier: workEndID, content: content, trigger: nil))
    }

    func clearWorkHoursEnded() {
        guard available else { return }
        center.removeDeliveredNotifications(withIdentifiers: [workEndID])
    }

    func status() async -> String {
        guard available else { return "Unavailable outside the app bundle" }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Denied — reminders cannot be shown"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replaces the whole schedule; safe to call at every launch and after every change.
    func reschedule(_ settings: SleepSettings) async {
        guard available else { return }
        center.removePendingNotificationRequests(withIdentifiers: weeklyIDs)
        guard settings.enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [snoozeID])
            return
        }
        for trigger in SleepSchedule.triggers(settings) {
            var when = DateComponents()
            when.weekday = trigger.weekday
            when.hour = trigger.hour
            when.minute = trigger.minute
            let request = UNNotificationRequest(identifier: "sleep-\(trigger.weekday)", content: content(settings),
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
            try? await center.add(request)
        }
    }

    func sendTest(_ settings: SleepSettings) async {
        guard available else { return }
        let request = UNNotificationRequest(identifier: "sleep-test", content: content(settings),
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        try? await center.add(request)
    }

    private func content(_ settings: SleepSettings) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let bedtime = Calendar.current.date(bySettingHour: settings.bedtimeMinutes / 60, minute: settings.bedtimeMinutes % 60, second: 0, of: Date()) ?? Date()
        let time = bedtime.formatted(date: .omitted, time: .shortened)
        content.title = "Time to wind down"
        content.body = settings.leadMinutes > 0 ? "Bedtime is at \(time), in \(settings.leadMinutes) minutes." : "It's \(time): bedtime."
        content.categoryIdentifier = sleepCategory
        content.sound = settings.sound ? .default : nil
        content.userInfo = ["snooze": settings.snoozeMinutes]
        return content
    }

    // Show reminders even while a WorkPulse window is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    // Snooze re-posts the reminder later. Dismiss (and a plain click) does nothing at all.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == endWorkAction {
            await MainActor.run { self.onEndWork?() }
            return
        }
        guard response.actionIdentifier == snoozeAction else { return }
        let original = response.notification.request.content
        let minutes = original.userInfo["snooze"] as? Int ?? 10
        let content = UNMutableNotificationContent()
        content.title = original.title
        content.body = "Snoozed reminder: time to head to bed."
        content.categoryIdentifier = sleepCategory
        content.sound = original.sound
        content.userInfo = original.userInfo
        let request = UNNotificationRequest(identifier: snoozeID, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(max(1, minutes)) * 60, repeats: false))
        try? await center.add(request)
    }
}
