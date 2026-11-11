import SwiftUI
import UserNotifications
import TwilDiaryCore

/// New-episode alerts, scheduled on this iPhone (no server): the next two weeks of episodes for
/// the shows you're watching, at 9 am on the day each airs. Rescheduled whenever the app opens.
@MainActor enum EpisodeNotifications {
    static let enabledKey = "episodeAlerts", askedKey = "episodeAlerts.asked"
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
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        await clear()
        let calendar = DiaryDate.calendar()
        for alert in EpisodeAlerts.upcoming(store.workspace, today: DiaryDate.day(store.now)) {
            let parts = alert.day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            var when = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 9)
            when.calendar = calendar; when.timeZone = calendar.timeZone
            // Today after 9 am: in a minute instead.
            if let date = calendar.date(from: when), date <= .now {
                guard calendar.isDateInToday(date) else { continue }
                when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: .now.addingTimeInterval(60))
            }
            let content = UNMutableNotificationContent()
            content.title = alert.title; content.body = alert.body; content.sound = .default
            content.threadIdentifier = alert.titleId
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
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
