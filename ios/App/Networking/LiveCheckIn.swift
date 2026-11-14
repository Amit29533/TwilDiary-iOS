import Foundation
import Observation
import SwiftUI
import UserNotifications
import TwilDiaryCore

/// The check-in running right now (Cinopsys's "active check-in"): what, on which service, and
/// when the service logs it.
struct ActiveCheckIn: Codable, Equatable, Sendable {
    let service: String
    let titleId: String
    let name: String
    let tmdbId: Int
    let isSeries: Bool
    let season: Int?
    let episode: Int?
    let startedAt: Date
    let endsAt: Date
    var tracker: MainTracker? { MainTracker(rawValue: service) }
    /// "Severance S2 E3", or the movie's name.
    var label: String { season.map { "\(name) S\($0) E\(episode ?? 0)" } ?? name }
}

/// Live check-in: checks in on the service, shows a banner with the time left and Cancel, and when
/// it ends (the service logs the watch itself) reads the service so the watch is in the diary.
/// Cancelling uses each service's own way, as Cinopsys does: Trakt DELETE /checkin, MDBList
/// scrobble/stop at 0 % then scrobble/clear, WeTrakr DELETE /scrobble/playing.
@MainActor @Observable final class LiveCheckIn {
    static let shared = LiveCheckIn()
    nonisolated private static let key = "activeCheckIn"
    private static let notificationID = "twildiary.checkin.end"
    private(set) var active: ActiveCheckIn? = LiveCheckIn.load() {
        didSet { UserDefaults.standard.set(active.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.key) }
    }
    private(set) var cancelling = false
    @ObservationIgnored private var ending: Task<Void, Never>?

    nonisolated private static func load() -> ActiveCheckIn? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ActiveCheckIn.self, from: $0) }
    }

    /// Checks in, then shows the banner until the watch ends (its runtime; 45 min for an episode
    /// and 110 for a movie when TMDB has none).
    func start(_ tracker: MainTracker, _ title: MediaTitle, episode: Episode?, store: DiaryStore) async throws {
        _ = try await TrackerPreviewStore.shared.checkIn(tracker, title, episode: episode, store: store)
        let minutes = max(1, title.runtimeMinutes.flatMap { $0 > 0 ? $0 : nil } ?? (title.isSeries ? 45 : 110))
        let now = Date.now
        let check = ActiveCheckIn(service: tracker.rawValue, titleId: title.id, name: title.name, tmdbId: title.tmdbId ?? 0, isSeries: title.isSeries,
                                  season: title.isSeries ? episode?.season : nil, episode: title.isSeries ? episode?.number : nil,
                                  startedAt: now, endsAt: now.addingTimeInterval(Double(minutes) * 60))
        withAnimation(.snappy) { active = check }
        scheduleEnd(store: store)
        await notifyAtEnd(check)
    }

    /// Cancel: the service forgets the check-in and nothing is logged.
    func cancel(store: DiaryStore) async {
        guard let active, let tracker = active.tracker, !cancelling else { return }
        cancelling = true
        defer { cancelling = false }
        do {
            switch tracker {
            case .trakt:
                _ = try await TraktDirectStore.shared.client(store: store).send("DELETE", "/checkin")
            case .wetrakr:
                let config = await store.freshProviderConfig(tracker.provider)
                _ = try await store.directClient.read(config, path: "/scrobble/playing", method: "DELETE")
            case .simkl:
                break
            case .mdblist:
                let config = await store.freshProviderConfig(tracker.provider)
                let slot = active.isSeries ? "show" : "movie"
                var media: [String: Any] = ["ids": ["tmdb": active.tmdbId]]
                if active.isSeries { media["season"] = active.season ?? 0; media["episode"] = active.episode ?? 0 }
                let body: [String: Any] = ["progress": 0, slot: media]
                _ = try await store.directClient.write(config, path: "/scrobble/stop", body: try JSONSerialization.data(withJSONObject: body))
                _ = try? await store.directClient.write(config, path: "/scrobble/clear", body: Data("{}".utf8))
            }
            finish(logged: false, store: store)
        } catch {
            store.error = "The check-in couldn’t be cancelled: " + error.localizedDescription
        }
    }

    /// On opening the app: a check-in that ended meanwhile is done (and the diary read); one still
    /// running keeps its banner.
    func resume(store: DiaryStore) {
        guard let active else { return }
        if active.endsAt <= .now { finish(logged: true, store: store) } else { scheduleEnd(store: store) }
    }

    private func scheduleEnd(store: DiaryStore) {
        ending?.cancel()
        guard let check = active else { return }
        ending = Task { [weak self] in
            let wait = check.endsAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled, self.active == check else { return }
            self.finish(logged: true, store: store)
        }
    }

    private func finish(logged: Bool, store: DiaryStore) {
        let ended = active
        withAnimation(.snappy) { active = nil }
        ending?.cancel(); ending = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        guard logged, let ended, let tracker = ended.tracker else { return }
        // The service logs the watch itself as the check-in ends: read it a moment later.
        if tracker == .trakt { TraktDirectStore.shared.refreshSoon(store: store, after: 20) }
        else { TrackerPreviewStore.shared.refreshSoon(tracker, store: store, after: 20) }
    }

    /// "Finished …" when the check-in ends, if alerts are allowed.
    private func notifyAtEnd(_ check: ActiveCheckIn) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Finished \(check.label)"
        content.body = "It’s logged on \(check.tracker?.name ?? "your tracker") and in your diary."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, check.endsAt.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: trigger))
    }

    /// "32 min left", "1 h 5 min left".
    nonisolated static func timeLeft(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }
}

/// The banner above the tab bar while a check-in runs: what, on which service, how far, and Cancel.
struct CheckInBanner: View {
    @Environment(DiaryStore.self) private var store
    private let live = LiveCheckIn.shared

    var body: some View {
        Group {
            if let check = live.active {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let total = check.endsAt.timeIntervalSince(check.startedAt)
                    let left = max(0, check.endsAt.timeIntervalSince(context.date))
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            .frame(width: 36, height: 36).background(HomeStyle.chip, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Checked in on \(check.tracker?.name ?? "your tracker") · \(LiveCheckIn.timeLeft(left))")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(HomeStyle.secondary).lineLimit(1).truncationMode(.tail)
                            Text(check.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
                            ProgressView(value: total > 0 ? min(1, max(0, 1 - left / total)) : 1).tint(HomeStyle.chipText)
                        }
                        Button { Task { await live.cancel(store: store) } } label: {
                            Text(live.cancelling ? "Cancelling…" : "Cancel").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                .padding(.horizontal, 14).frame(height: 34).background(HomeStyle.chip, in: Capsule()).contentShape(Capsule())
                        }.buttonStyle(.plain).disabled(live.cancelling).accessibilityIdentifier("check-in-cancel")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(HomeStyle.cardBorder, lineWidth: 1))
                }
                .padding(.horizontal, 16).padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain).accessibilityIdentifier("check-in-banner")
            }
        }
        .task { live.resume(store: store) }
    }
}
