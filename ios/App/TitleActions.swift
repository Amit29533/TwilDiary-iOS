import Foundation
import TwilDiaryCore

@MainActor final class SeasonEditTransaction {
    enum Change { case record(id: String, episode: String, date: String), revoke(WatchEvent) }
    var remaining: [Change]
    let count: Int
    var undo: [(event: WatchEvent, action: String)] = []
    init(plan: SeasonAdjustment, count: Int, date: Date) {
        self.count = count
        remaining = plan.revoke.map(Change.revoke) + plan.record.map { .record(id: UUID().uuidString, episode: $0.id, date: date.ISO8601Format()) }
    }
}

extension DiaryStore {
    /// The status menu on a show detail belongs to the selected season. The
    /// whole-title progress endpoint deliberately edits every season, so it
    /// must never be used here for Completed or Planned.
    @discardableResult func setSeasonStatus(_ title: MediaTitle, season: Int, status: String, watchedAt: Date) async -> Bool {
        guard title.isSeries else { return await setStatus(title, status: status, watchedAt: watchedAt) }
        if status == "planned" { return await setSeasonProgress(title, season: season, count: 0, watchedAt: watchedAt) }
        if status == "completed" {
            return await perform {
                try await self.prepareSavedSeason(title, number: season)
                guard let current = self.title(title.id) else { throw CancellationError() }
                try await self.applySeasonProgress(current, season: season, count: self.seasonProgress(current, season: season).total, watchedAt: watchedAt)
            }
        }
        return await patch(title, values: ["status": status])
    }
    func seasonStatus(_ title: MediaTitle, season: Int) -> String {
        guard title.isSeries else { return title.status }
        if title.status == "dropped" { return "dropped" }
        let progress = seasonProgress(title, season: season)
        if progress.total > 0 && progress.watched >= progress.total { return "completed" }
        return progress.watched > 0 ? "watching" : "planned"
    }
    @discardableResult func setSeasonProgress(_ title: MediaTitle, season: Int, count: Int, watchedAt: Date) async -> Bool {
        await perform { try await self.applySeasonProgress(title, season: season, count: count, watchedAt: watchedAt) }
    }
    @discardableResult func completeCardSeason(_ titleID: String, season: Int) async -> Bool {
        await perform(cardID: titleID) {
            guard let title = self.title(titleID), title.isSeries else { throw APIError.message("Choose a show season.") }
            try await self.prepareSavedSeason(title, number: season)
            guard let refreshed = self.title(titleID) else { throw CancellationError() }
            let progress = SeasonProgress.calculate(title: refreshed, workspace: self.workspace, season: season)
            // This intentionally completes only this season. Future/unknown episodes are rejected by the existing plan.
            try await self.applySeasonProgress(refreshed, season: season, count: progress.total, watchedAt: self.now)
        }
    }
    private func applySeasonProgress(_ title: MediaTitle, season: Int, count: Int, watchedAt: Date) async throws {
            guard DiaryDate.day(watchedAt) <= DiaryDate.day(self.now) else { throw APIError.message("Choose today or a past watch date") }
            let key = title.id + ":" + String(season)
            if self.pendingSeasonAdjustments[key] == nil {
                let progress = SeasonProgress.calculate(title: title, workspace: self.workspace, season: season)
                let loaded = self.workspace.episodes.filter { $0.titleId == title.id && $0.season == season }.count
                guard progress.total == loaded, loaded > 0 else { throw APIError.message("Load this season’s complete episode list before adjusting progress.") }
                let plan = try SeasonAdjustment.plan(workspace: self.workspace, titleID: title.id, season: season, count: count, today: DiaryDate.day(self.now))
                self.pendingSeasonAdjustments[key] = SeasonEditTransaction(plan: plan, count: count, date: watchedAt)
            }
            guard let transaction = self.pendingSeasonAdjustments[key] else { return }
            guard transaction.count == count else { throw APIError.message("An earlier progress change is unconfirmed. Retry its original episode count before making a different change.") }
            do {
            while let change = transaction.remaining.first {
                switch change {
                case .record(let operation, let episode, let date):
                    let receipt: EpisodeWatchReceipt = try await self.read("/api/titles/\(title.id)/watches", method: "POST", body: ["operationId": operation, "episodeId": episode, "watchedAt": date, "rewatch": false])
                    if receipt.added || (receipt.event.operationId == operation && receipt.event.version == 1 && receipt.event.revokedAt == nil) {
                        transaction.undo.append((receipt.event, "revoke"))
                    }
                case .revoke(let event):
                    let receipt: EpisodeEventReceipt = try await self.read("/api/watch-events/\(event.id)", method: "PATCH", body: ["action": "revoke", "expectedVersion": event.version ?? 1])
                    transaction.undo.append((receipt.event, "restore"))
                }
                transaction.remaining.removeFirst()
                self.installUndo(transaction.undo, label: "Season progress updated")
            }
            self.pendingSeasonAdjustments.removeValue(forKey: key)
            } catch { self.rejectPendingSeason(key: key, error: error); throw error }
    }

    @discardableResult func recordViewing(_ title: MediaTitle, episode: Episode? = nil, rewatch: Bool = false, watchedAt: Date) async -> Bool {
        await perform {
            guard DiaryDate.day(watchedAt) <= DiaryDate.day(self.now) else { throw APIError.message("Choose today or a past watch date") }
            if title.isSeries {
                guard let episode, episode.titleId == title.id,
                      episode.airedOn.map({ SeasonAdjustment.validDay($0) && $0 <= DiaryDate.day(self.now) }) == true else {
                    throw APIError.message("Unreleased episodes cannot be marked watched")
                }
            }
            let key = "viewing:" + title.id + ":" + (episode?.id ?? "movie") + (rewatch ? ":rewatch" : ":watch")
            let operation = self.pendingViewing(key: key, episode: episode?.id, date: watchedAt, rewatch: rewatch)
            let receipt: EpisodeWatchReceipt
            do { receipt = try await self.read("/api/titles/\(title.id)/watches", method: "POST", body: operation) }
            catch { self.rejectPendingViewing(key: key, error: error); throw error }
            self.clearPendingViewing(key: key)
            if receipt.added || (receipt.event.operationId == operation["operationId"] as? String && receipt.event.version == 1 && receipt.event.revokedAt == nil) {
                self.installUndo([(receipt.event, "revoke")], label: "Watch marked")
            }
        }
    }

    @discardableResult func unwatchEpisode(_ episode: Episode) async -> Bool {
        let reviewed = workspace.activeEvents.filter { $0.titleId == episode.titleId && $0.episodeId == episode.id }
        return await perform {
            var undo: [(event: WatchEvent, action: String)] = []
            for event in reviewed {
                let receipt: EpisodeEventReceipt = try await self.read("/api/watch-events/\(event.id)", method: "PATCH", body: ["action": "revoke", "expectedVersion": event.version ?? 1])
                undo.append((receipt.event, "restore"))
                self.installUndo(undo, label: "Watch removed")
            }
        }
    }

    func revealedSeason(_ title: MediaTitle, number: Int) async throws -> [RevealedEpisode] {
        if isPreview { return workspace.episodes.filter { $0.titleId == title.id && $0.season == number }.map(RevealedEpisode.init) }
        var result: [RevealedEpisode] = [], after: Int?, visited = Set<Int>()
        repeat {
            let path = CatalogTools.apiPath("/api/titles/\(title.id)/seasons/\(number)", query: ["reveal": "1", "limit": "100", "after": String(after ?? 0)])
            let page: RevealedSeasonPage = try await read(path)
            result.append(contentsOf: page.items); after = page.nextAfter
            if let after, !visited.insert(after).inserted { throw APIError.message("The season returned a repeated page. Refresh and try again.") }
        } while after != nil
        return result
    }
}

private struct EpisodeWatchReceipt: Decodable { let event: WatchEvent; let added: Bool }
private struct EpisodeEventReceipt: Decodable { let event: WatchEvent }
private struct RevealedSeasonPage: Decodable { let items: [RevealedEpisode]; let nextAfter: Int? }
struct RevealedEpisode: Decodable, Identifiable, Sendable {
    let id: String
    let number: Int
    let name: String?
    let overview: String?
    let stillPath: String?
    let communityScore: Double?
    init(_ episode: Episode) {
        id = episode.id; number = episode.number; name = episode.name; overview = episode.overview
        stillPath = episode.still; communityScore = episode.communityScore
    }
    var artwork: String? { stillPath.flatMap { $0.hasPrefix("/") ? CatalogTools.image($0) : $0 } }
}
