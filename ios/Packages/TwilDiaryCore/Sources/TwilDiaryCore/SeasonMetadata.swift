import Foundation

public enum SeasonMetadata {
    /// Mirrors the selected-season freshness/complete-snapshot gate in live-diary.
    public static func needsPreparation(title: MediaTitle, workspace: Workspace, season: Int, now: Date) -> Bool {
        guard title.isSeries, title.tmdbId != nil, let manifest = title.seasons?.first(where: { $0.number == season }) else { return false }
        let fresh = (manifest.metadataVersion ?? 1) >= 2 && DiaryDate.parse(manifest.metadataLoadedAt).map { now.timeIntervalSince($0) < 6 * 60 * 60 } == true
        let count = workspace.episodes.filter { $0.titleId == title.id && $0.season == season }.count
        return !fresh || manifest.expectedEpisodes != count
    }
}
