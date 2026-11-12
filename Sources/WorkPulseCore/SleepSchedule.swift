import Foundation

/// A weekly repeating reminder time. `weekday`: 1 = Sunday … 7 = Saturday.
public struct ReminderTrigger: Equatable, Hashable, Sendable {
    public var weekday: Int
    public var hour: Int
    public var minute: Int
}

/// Pure scheduling maths for sleep reminders; the app hands the triggers to macOS notifications.
public enum SleepSchedule {
    /// When reminders fire: `leadMinutes` before bedtime on each selected day. A reminder for an
    /// early-morning bedtime can land on the evening of the previous weekday.
    public static func triggers(_ s: SleepSettings) -> [ReminderTrigger] {
        guard s.enabled else { return [] }
        return s.days.sorted().map { day in
            var minutes = s.bedtimeMinutes - s.leadMinutes
            var weekday = day
            while minutes < 0 {
                minutes += 1440
                weekday = weekday == 1 ? 7 : weekday - 1
            }
            return ReminderTrigger(weekday: weekday, hour: minutes / 60, minute: minutes % 60)
        }
    }

    public static func nextFire(after date: Date, settings: SleepSettings, calendar: Calendar = .current) -> Date? {
        triggers(settings).compactMap { t in
            calendar.nextDate(after: date, matching: DateComponents(hour: t.hour, minute: t.minute, weekday: t.weekday),
                              matchingPolicy: .nextTime)
        }.min()
    }
}
