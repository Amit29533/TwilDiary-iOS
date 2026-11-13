import SwiftUI
import UserNotifications
import TwilDiaryCore

/// New-episode alerts, scheduled on this iPhone (no server): the next two weeks of episodes for
/// the shows on your calendar, at 9 am on the day each airs. Rescheduled when the diary loads or
/// changes, whenever the app opens, and in the background refresh.
@MainActor enum EpisodeNotifications {
    static let enabledKey = "episodeAlerts", askedKey = "episodeAlerts.asked"
    private static let scheduledKey = "episodeAlerts.scheduled"
    /// iOS lets TwilDiary's alerts through.
    static func allowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return [.authorized, .provisional, .ephemeral].contains(status)
    }
    /// Alerts also show while TwilDiary is open (iOS hides them otherwise). Set once at launch.
    static func showWhileOpen() { UNUserNotificationCenter.current().delegate = AlertPresenter.shared }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Asks iOS once; on yes, alerts are on and scheduled.
    @discardableResult static func enable(store: DiaryStore) async -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        if granted { await reschedule(store: store) }
        return granted
    }
    static func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        Task { await clear() }
    }
    private static func clear() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("episode|") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    /// Replaces the scheduled alerts with the current next two weeks.
    static func reschedule(store: DiaryStore) async {
        guard enabled, !store.isPreview, store.hasLoadedWorkspace else { return }
        let center = UNUserNotificationCenter.current()
        guard await allowed() else { return }
        let today = DiaryDate.day(store.now)
        // Alerts already set (kept until their day passes): one whose 9 am has passed went off then,
        // so opening the app later that day doesn't send it again.
        var scheduled = Set(UserDefaults.standard.stringArray(forKey: scheduledKey) ?? []).filter { ($0.split(separator: "|").last.map(String.init) ?? "") >= today }
        await clear()
        let calendar = DiaryDate.calendar()
        for alert in EpisodeAlerts.upcoming(store.workspace, today: today) {
            let parts = alert.day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            var when = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 9)
            when.calendar = calendar; when.timeZone = calendar.timeZone
            // Today after 9 am: in a minute instead.
            if let date = calendar.date(from: when), date <= .now {
                guard calendar.isDateInToday(date), !scheduled.contains(alert.id) else { continue }
                when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: .now.addingTimeInterval(60))
            }
            let content = UNMutableNotificationContent()
            content.title = alert.title; content.body = alert.body; content.sound = .default
            content.threadIdentifier = alert.titleId
            do {
                try await center.add(UNNotificationRequest(identifier: alert.id, content: content,
                                                           trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
                scheduled.insert(alert.id)
            } catch { continue }
        }
        UserDefaults.standard.set(Array(scheduled), forKey: scheduledKey)
    }
    /// One line for Settings: whether iOS lets alerts through, and the next one set.
    static func summary() async -> String {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .denied { return "Notifications are off for TwilDiary in the iOS Settings app." }
        let next = await center.pendingNotificationRequests().compactMap { request -> (date: Date, title: String)? in
            guard let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { return nil }
            return (date, request.content.title)
        }.min { $0.date < $1.date }
        guard let next else { return "No alert set: nothing you follow airs in the next two weeks." }
        return "Next: \(next.title), \(next.date.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()))"
    }
}

/// Shows an alert as a banner while TwilDiary is open; without it iOS drops it silently.
final class AlertPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = AlertPresenter()
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// "Turn on notifications", asked once after your diary first loads (as Cinopsys asks).
struct EpisodeAlertsPrompt: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                .frame(width: 58, height: 58).background(HomeStyle.chip, in: Circle())
            Text("Turn on notifications").font(.system(size: 22, weight: .bold)).foregroundStyle(HomeStyle.primary)
            Text("Never miss a new episode of the shows you watch.").font(.system(size: 15)).foregroundStyle(HomeStyle.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Not now") { UserDefaults.standard.set(true, forKey: EpisodeNotifications.askedKey); dismiss() }
                    .buttonStyle(SettingsWideButtonStyle()).accessibilityIdentifier("alerts-not-now")
                Button("Enable") { Task { await EpisodeNotifications.enable(store: store); dismiss() } }
                    .buttonStyle(SettingsPrimaryButtonStyle()).accessibilityIdentifier("alerts-enable")
            }.padding(.top, 6)
        }.padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 12)
            .presentationDetents([.height(300)]).presentationDragIndicator(.visible)
    }
}
