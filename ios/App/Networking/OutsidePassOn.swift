import Foundation
import TwilDiaryCore

/// Part of "Send my edits" (owner's request, 2026-11-19): what reaches the service holding your
/// diary from somewhere else (a watch Infuse scrobbles to Trakt, a rating made on trakt.tv) goes
/// on to your other services as your own edits do, through the same path. Each service's "Send my
/// edits" switch (Simkl's and AniList's own) decides whether it gets it. Only additions, never
/// a removal; a whole history imported at once waits for a match you start yourself.
extension DiaryStore {
    func passOn(_ changes: OutsideChanges) {
        guard !changes.isEmpty, !isPreview else { return }
        Task { @MainActor in
            // The diary is rebuilt from the read in the background: wait until it has these titles.
            for _ in 0..<40 {
                if changes.keys.allSatisfy({ self.diaryTitleID($0) != nil }) { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            let recorded = Date.now.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            var passed = 0
            for play in changes.plays {
                guard let titleID = diaryTitleID(play.key) else { continue }
                var episodeID: String?
                if let season = play.season, let number = play.episode {
                    guard let episode = episodesForSeason(titleID, season: season).first(where: { $0.number == number })
                            ?? workspace.episodes.first(where: { $0.titleId == titleID && $0.season == season && $0.number == number }) else { continue }
                    episodeID = episode.id
                }
                mirror(.markWatch(operationId: "outside-" + UUID().uuidString, titleId: titleID, episodeId: episodeID,
                                  watchedAt: play.watchedAt, recordedAt: recorded, rewatch: play.rewatch))
                passed += 1
            }
            for (title, rating) in changes.ratings {
                guard let titleID = diaryTitleID(title.key) else { continue }
                mirror(.patchTitle(titleId: titleID, expectedVersion: nil, status: nil, score: Double(rating), clearScore: false, favorite: nil, queued: nil, notes: nil))
                passed += 1
            }
            for (titles, status) in [(changes.planned, "planned"), (changes.dropped, "dropped")] {
                for title in titles {
                    guard let titleID = diaryTitleID(title.key) else { continue }
                    mirror(.patchTitle(titleId: titleID, expectedVersion: nil, status: status, score: nil, clearScore: false, favorite: nil, queued: nil, notes: nil))
                    passed += 1
                }
            }
            if passed > 0 { outsidePassedOn += passed }
        }
    }

    /// The diary's title for "tv:1399".
    func diaryTitleID(_ key: String) -> String? {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let id = Int(parts[1]) else { return nil }
        return libraryIdentity(CatalogItem(id: id, mediaType: parts[0] == "movie" ? .movie : .tv, name: ""))
    }
}
