import Foundation
import UserNotifications

/// Local notifications for items with a due time: a heads-up a few minutes before, and one when it's due.
/// Off by default; turned on in Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A notification was clicked: open this page (or just the panel, when nil).
    var onOpen: (String?) -> Void = { _ in }
    /// "Mark done" was chosen on a notification for this page.
    var onMarkDone: (String) -> Void = { _ in }

    private static let category = "notionbar.item"
    private static let doneAction = "notionbar.done"
    private static let openAction = "notionbar.open"

    /// Notifications need a real `.app`; a bare binary run from the build folder has no bundle to ask as.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? {
        isAvailable ? UNUserNotificationCenter.current() : nil
    }

    func activate() {
        guard let center else { return }
        center.delegate = self
        let done = UNNotificationAction(identifier: Notifier.doneAction, title: "Mark Done", options: [])
        let open = UNNotificationAction(identifier: Notifier.openAction, title: "Open in Notion", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Notifier.category, actions: [done, open], intentIdentifiers: [], options: []),
        ])
    }

    /// Asks macOS for permission (the system shows its prompt the first time).
    func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replaces everything scheduled with alerts for the items that are still to come.
    func schedule(_ items: [Item], now: Date, leadMinutes: Int) {
        guard let center else { return }
        center.removeAllPendingNotificationRequests()

        let horizon = now.addingTimeInterval(7 * 24 * 3600)
        let upcoming = items
            .compactMap { item in item.due?.time.map { (item: item, time: $0) } }
            .filter { $0.time > now && $0.time < horizon }
            .sorted { $0.time < $1.time }
            .prefix(30)   // macOS keeps at most 64 pending per app

        scheduleMorningSummaries(center, items: items, now: now)

        for entry in upcoming {
            let subtitle = entry.item.kind == .step && !entry.item.parentName.isEmpty ? entry.item.parentName : ""
            if leadMinutes > 0 {
                let early = entry.time.addingTimeInterval(TimeInterval(-leadMinutes * 60))
                if early > now {
                    add(center, id: "lead|" + entry.item.id, at: early, item: entry.item,
                        title: "due in \(leadMinutes) min · \(Schedule.clock(entry.time))", subtitle: subtitle)
                }
            }
            add(center, id: "due|" + entry.item.id, at: entry.time, item: entry.item,
                title: "due now · \(Schedule.clock(entry.time))", subtitle: subtitle)
        }
    }

    /// When the morning summary goes out.
    static let summaryHour = 7
    static let summaryMinute = 30

    /// Things due on a day with no time of day can't alert "when due", so each such day gets one
    /// summary in the morning: "3 due today".
    private func scheduleMorningSummaries(_ center: UNUserNotificationCenter, items: [Item], now: Date) {
        let today = Day(now)
        var byDay: [Day: [Item]] = [:]
        for item in items {
            guard let due = item.due, due.time == nil, due.start >= today, due.start <= today.adding(7) else { continue }
            byDay[due.start, default: []].append(item)
        }
        for (day, dueThatDay) in byDay {
            var parts = DateComponents(year: day.year, month: day.month, day: day.day,
                                       hour: Notifier.summaryHour, minute: Notifier.summaryMinute)
            parts.calendar = Day.calendar
            guard let fireAt = Day.calendar.date(from: parts), fireAt > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = dueThatDay.count == 1 ? "1 thing due today" : "\(dueThatDay.count) things due today"
            content.body = dueThatDay.prefix(4).map(\.name).joined(separator: " · ")
                + (dueThatDay.count > 4 ? " · …" : "")
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Day.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt), repeats: false)
            center.add(UNNotificationRequest(identifier: "summary|" + day.iso, content: content, trigger: trigger))
        }
    }

    func cancelAll() {
        center?.removeAllPendingNotificationRequests()
    }

    func focusFinished(_ session: FocusTimer.Session) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session.minutes) min of focus done"
        content.body = session.item.name
        content.sound = .default
        content.categoryIdentifier = Notifier.category
        content.userInfo = ["page": session.item.id]
        center.add(UNNotificationRequest(identifier: "focus|" + session.item.id, content: content, trigger: nil))
    }

    private func add(_ center: UNUserNotificationCenter, id: String, at date: Date, item: Item,
                     title: String, subtitle: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = item.name
        if !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound = .default
        content.categoryIdentifier = Notifier.category
        content.userInfo = ["page": item.id]
        let parts = Day.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let page = response.notification.request.content.userInfo["page"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Notifier.doneAction, let page {
                self.onMarkDone(page)
            } else if action == Notifier.openAction {
                self.onOpen(page)
            } else if action == UNNotificationDefaultActionIdentifier {
                self.onOpen(nil)
            }
        }
    }
}
