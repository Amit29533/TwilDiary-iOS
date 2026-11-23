import SwiftUI
import UserNotifications
import Intents
import TwilDiaryCore

/// New-episode alerts, scheduled on this iPhone (no server): the next two weeks of episodes for
/// the shows on your calendar, at 9 am on the day each airs (never before it has, when its air time
/// is known). Rescheduled when the diary loads or changes, whenever the app opens, and in the
/// background refresh.
@MainActor enum EpisodeNotifications {
    static let enabledKey = "episodeAlerts", askedKey = "episodeAlerts.asked"
    /// When each alert was set to go off, by its id.
    private static let timesKey = "episodeAlerts.times"
    /// The ids alone, as older builds kept them.
    private static let scheduledKey = "episodeAlerts.scheduled"
    private static var work: Task<Void, Never>?
    private static var waiting = false
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
    static func clear() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("episode|") }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    /// Brings the scheduled alerts up to the current next two weeks. One at a time: asked while it's at
    /// it, it goes again after (once, however many ask).
    static func reschedule(store: DiaryStore) async {
        guard enabled, !store.isPreview, store.hasLoadedWorkspace else { return }
        if work != nil {
            guard !waiting else { return }
            waiting = true
            while let running = work { await running.value }
            waiting = false
        }
        let task = Task {
            defer { work = nil }
            await place(store: store)
        }
        work = task
        // Background time up: what's under way stops too, so the app can say it's done in time.
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    /// Each alert is added (or replaced, by its id), and only then do those no longer wanted go. They
    /// were all cleared first, so one interrupted (the app put away, its background time up) lost the
    /// rest until the next time the app opened.
    private static func place(store: DiaryStore) async {
        guard await allowed() else { return }
        let center = UNUserNotificationCenter.current(), calendar = DiaryDate.calendar()
        // From yesterday: an episode of the network's yesterday can be out here today.
        let from = DiaryDate.day(calendar.date(byAdding: .day, value: -1, to: store.now) ?? store.now)
        let alerts = EpisodeAlerts.upcoming(store.workspace, today: from, days: 15, limit: 60)
        var times = savedTimes(calendar).filter { ($0.key.split(separator: "|").last.map(String.init) ?? "") >= from }
        func wanted() -> [(alert: EpisodeAlerts.Alert, at: Date)] {
            let now = Date.now
            return alerts.compactMap { alert -> (alert: EpisodeAlerts.Alert, at: Date)? in
                let airs = EpisodeAirTimes.shared.time(tmdb: store.title(alert.titleId)?.tmdbId, season: alert.season, number: alert.number, day: alert.day)
                guard let at = EpisodeAlerts.moment(day: alert.day, airs: airs, calendar: calendar) else { return nil }
                // Set before, and its moment has passed: it went off then.
                if let set = times[alert.id], set <= now { return nil }
                if at > now { return (alert, at) }
                // Out already today and never set: in a minute instead.
                return calendar.isDateInToday(at) ? (alert, now.addingTimeInterval(60)) : nil
            }.sorted { $0.at < $1.at }.prefix(40).map { $0 }
        }
        func set(_ entry: (alert: EpisodeAlerts.Alert, at: Date)) async {
            let alert = entry.alert
            let content = UNMutableNotificationContent()
            content.title = alert.title; content.body = alert.body; content.sound = .default
            content.threadIdentifier = alert.titleId
            content.userInfo = [AlertOpening.key: alert.titleId]
            let finished = await NotificationArtwork.finish(content, from: alert.title, conversation: alert.titleId, poster: store.title(alert.titleId)?.poster)
            var when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: entry.at)
            when.calendar = calendar; when.timeZone = calendar.timeZone
            guard (try? await center.add(UNNotificationRequest(identifier: alert.id, content: finished,
                                                               trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))) != nil else { return }
            times[alert.id] = entry.at
        }
        let first = wanted()
        for entry in first { await set(entry) }
        UserDefaults.standard.set(times, forKey: timesKey)
        guard !Task.isCancelled else { return }
        // Air times not known yet, for the next few days: the alerts they move are set again.
        await learnAirTimes(alerts, store: store, calendar: calendar)
        let current = wanted()
        let before = Dictionary(first.map { ($0.alert.id, $0.at) }, uniquingKeysWith: { one, _ in one })
        for entry in current where before[entry.alert.id].map({ abs($0.timeIntervalSince(entry.at)) > 120 }) ?? true { await set(entry) }
        let keep = Set(current.map(\.alert.id))
        let stale = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("episode|") && !keep.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        UserDefaults.standard.set(times, forKey: timesKey)
    }
    /// When each alert was set to go off. From an older build, which kept only which were set: 9 am on
    /// their day, as that build set them.
    private static func savedTimes(_ calendar: Calendar) -> [String: Date] {
        let defaults = UserDefaults.standard
        if let times = defaults.dictionary(forKey: timesKey) as? [String: Date] { return times }
        var times: [String: Date] = [:]
        for id in defaults.stringArray(forKey: scheduledKey) ?? [] {
            times[id] = id.split(separator: "|").last.flatMap { EpisodeAlerts.moment(day: String($0), airs: nil, calendar: calendar) }
        }
        defaults.removeObject(forKey: scheduledKey)
        return times
    }
    /// The air times of the next few days' episodes (Trakt's calendar, else TVmaze), kept once found.
    private static func learnAirTimes(_ alerts: [EpisodeAlerts.Alert], store: DiaryStore, calendar: Calendar) async {
        await TraktAirTimes.shared.refresh(store: store)
        let soon = DiaryDate.day(calendar.date(byAdding: .day, value: 4, to: .now) ?? .now)
        for alert in alerts.filter({ $0.day <= soon }).prefix(12) {
            await EpisodeAirTimes.shared.load(tmdb: store.title(alert.titleId)?.tmdbId, season: alert.season, number: alert.number, day: alert.day, store: store)
        }
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
        return "Next: \(next.title), \(next.date.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute().locale(.diaryClock)))"
    }
}

/// The show's or anime's poster on its alert. Sent as a message from the show (Communication
/// Notifications, owner's request), the poster takes the app icon's place; it's also attached, so
/// without that permission the alert still shows it beside the text (and in full when you press
/// and hold). Each poster is downloaded once and kept on the phone.
@MainActor enum NotificationArtwork {
    private static let folder = URL.cachesDirectory.appending(path: "NotificationArt", directoryHint: .isDirectory)
    static func finish(_ content: UNMutableNotificationContent, from name: String, conversation: String, poster: String?) async -> UNNotificationContent {
        guard let file = await saved(poster) else { return content }
        if let picture = attachment(file) { content.attachments = [picture] }
        guard let data = try? Data(contentsOf: file) else { return content }
        let body = content.body
        // One message for iOS's record of it, one for the alert (each built from plain values).
        func message() -> INSendMessageIntent {
            let image = INImage(imageData: data)
            let sender = INPerson(personHandle: INPersonHandle(value: conversation, type: .unknown), nameComponents: nil, displayName: name,
                                  image: image, contactIdentifier: nil, customIdentifier: conversation)
            let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: body, speakableGroupName: nil,
                                             conversationIdentifier: conversation, serviceName: nil, sender: sender, attachments: nil)
            intent.setImage(image, forParameterNamed: \.sender)
            return intent
        }
        let interaction = INInteraction(intent: message(), response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return (try? content.updating(from: message())) ?? content
    }
    /// The poster on the phone (downloaded the first time).
    private static func saved(_ poster: String?) async -> URL? {
        guard let poster, let url = URL(string: poster), url.scheme == "https" else { return nil }
        let ext = ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "jpg"
        let name = String(poster.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }, radix: 16)
        let saved = folder.appending(path: name + "." + ext)
        if FileManager.default.fileExists(atPath: saved.path) { return saved }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200, !reply.0.isEmpty, reply.0.count < 3_000_000 else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? reply.0.write(to: saved, options: .atomic)) != nil ? saved : nil
    }
    /// iOS moves an attachment's file into its own store, so each alert gets a fresh copy.
    private static func attachment(_ saved: URL) -> UNNotificationAttachment? {
        let copy = URL.temporaryDirectory.appending(path: UUID().uuidString + "." + saved.pathExtension)
        guard (try? FileManager.default.copyItem(at: saved, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "poster", url: copy)
    }
}

/// The title of an alert you tapped, until its page has opened (on a cold launch, once the diary is
/// there).
@MainActor @Observable final class AlertOpening {
    static let shared = AlertOpening()
    nonisolated static let key = "titleId"
    var titleID: String?
    /// The title an alert is about. One an older build set has it only in its id ("episode|<title>|<day>").
    nonisolated static func titleID(_ info: [AnyHashable: Any], identifier: String) -> String? {
        if let id = info[key] as? String { return id }
        let parts = identifier.split(separator: "|")
        guard parts.count >= 3, parts[0] == "episode" else { return nil }
        return parts.dropFirst().dropLast().joined(separator: "|")
    }
}

/// A tapped alert opens its title's page, in the tab you're on (it only opened the app before).
struct AlertOpens: ViewModifier {
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    func body(content: Content) -> some View {
        content.task(id: AlertOpening.shared.titleID) {
            guard let id = AlertOpening.shared.titleID else { return }
            for _ in 0..<40 where store.title(id) == nil {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            AlertOpening.shared.titleID = nil
            guard store.title(id) != nil else { return }
            router.randomPick = nil
            router.openTitle(id, tab: router.selectedTab)
        }
    }
}

/// Shows an alert as a banner while TwilDiary is open; without it iOS drops it silently. Tapped, it
/// opens its title.
final class AlertPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = AlertPresenter()
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let id = AlertOpening.titleID(request.content.userInfo, identifier: request.identifier) {
            Task { @MainActor in AlertOpening.shared.titleID = id }
        }
        completionHandler()
    }
}

/// "Turn on notifications", asked once after your diary first loads (as Cinopsys asks).
struct EpisodeAlertsPrompt: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bell.fill").font(.app(size: 26, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                .frame(width: 58, height: 58).background(HomeStyle.chip, in: Circle())
            Text("Turn on notifications").font(.app(size: 22, weight: .bold)).foregroundStyle(HomeStyle.primary)
            Text("Never miss a new episode of the shows you watch.").font(.app(size: 15)).foregroundStyle(HomeStyle.secondary)
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
