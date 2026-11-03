import Foundation

public enum DiaryExportError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Unsupported diary archive schema version (\(version))."
        }
    }
}

/// The same complete archive envelope as the web export, including Trash and revoked history.
public struct DiaryExport: Codable, Sendable {
    public let schemaVersion: Int
    public let titles: [MediaTitle]
    public let episodes: [Episode]
    public let events: [WatchEvent]
    public let locations: [FileLocation]
    public let skippedEpisodeIds: [String]
    public init(workspace: Workspace) {
        schemaVersion = 1; titles = workspace.titles; episodes = workspace.episodes
        events = workspace.events; locations = workspace.locations
        skippedEpisodeIds = workspace.episodes.filter { $0.skipped == true }.map(\.id)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    public static func decoded(from data: Data) throws -> DiaryExport {
        if let archive = try? JSONDecoder().decode(DiaryExport.self, from: data) {
            guard archive.schemaVersion == 1 else {
                throw DiaryExportError.unsupportedSchema(archive.schemaVersion)
            }
            _ = try archive.toWorkspace()
            return archive
        }
        // CSV uploads are parsed by the server's canonical parser; decoding here is JSON-only.
        let archive = try JSONDecoder().decode(DiaryExport.self, from: data)
        guard archive.schemaVersion == 1 else { throw DiaryExportError.unsupportedSchema(archive.schemaVersion) }
        _ = try archive.toWorkspace()
        return archive
    }
    public func toWorkspace() throws -> Workspace {
        guard schemaVersion == 1 else {
            throw DiaryExportError.unsupportedSchema(schemaVersion)
        }
        let skippedSet = Set(skippedEpisodeIds)
        let restoredEpisodes = episodes.map { ep -> Episode in
            guard skippedSet.contains(ep.id), ep.skipped != true else { return ep }
            var copy = ep
            copy.skipped = true
            return copy
        }
        return try Workspace(
            titles: titles,
            episodes: restoredEpisodes,
            events: events,
            locations: locations
        ).validatingIdentities()
    }
    /// Deterministically merges this archive into `base` (for cross-device sync, iCloud backup,
    /// or standalone local recovery), filling absent personal fields while preserving current edits and tombstones.
    public func merged(into base: Workspace) throws -> Workspace {
        let base = try base.validatingIdentities()
        let incoming = try toWorkspace()

        // Archive versions belong to another timeline and are not authority over current edits.
        var titleByID = Dictionary(uniqueKeysWithValues: base.titles.map { ($0.id, $0) })
        for item in incoming.titles {
            if let existing = titleByID[item.id] {
                var merged = existing
                if merged.score == nil { merged.score = item.score }
                if merged.notes.isEmpty { merged.notes = item.notes }
                if (merged.tags ?? []).isEmpty { merged.tags = item.tags }
                merged.favorite = merged.favorite || item.favorite
                if item.queued == true { merged.queued = true }
                if merged != existing { merged.version = (existing.version ?? 1) + 1 }
                titleByID[item.id] = merged
            } else { titleByID[item.id] = item }
        }
        let mergedTitles = titleByID.values.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        let validTitleIDs = Set(mergedTitles.map(\.id))

        // 2. Merge episodes by ID, preserving `skipped == true` from either side.
        var episodeByID = Dictionary(uniqueKeysWithValues: base.episodes.map { ($0.id, $0) })
        for ep in incoming.episodes where validTitleIDs.contains(ep.titleId) {
            if var existing = episodeByID[ep.id] {
                if ep.skipped == true { existing.skipped = true }
                episodeByID[ep.id] = existing
            } else {
                episodeByID[ep.id] = ep
            }
        }
        let mergedEpisodes = episodeByID.values
            .filter { validTitleIDs.contains($0.titleId) }
            .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }

        // 3. Merge watch events by ID and deduplicate by `operationId`, preserving highest version & revocations.
        var eventByID = Dictionary(uniqueKeysWithValues: base.events.map { ($0.id, $0) })
        var seenOperationIDs = Set(base.events.map(\.operationId))
        for ev in incoming.events where validTitleIDs.contains(ev.titleId) {
            if eventByID[ev.id] == nil && !seenOperationIDs.contains(ev.operationId) {
                eventByID[ev.id] = ev
                seenOperationIDs.insert(ev.operationId)
            }
        }
        let mergedEvents = eventByID.values
            .filter { validTitleIDs.contains($0.titleId) }
            .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }

        // 4. Merge file locations by ID.
        var locationByID = Dictionary(uniqueKeysWithValues: base.locations.map { ($0.id, $0) })
        for loc in incoming.locations where validTitleIDs.contains(loc.titleId) {
            locationByID[loc.id] = loc
        }
        let mergedLocations = locationByID.values
            .filter { validTitleIDs.contains($0.titleId) }
            .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }

        return try Workspace(
            titles: mergedTitles,
            episodes: mergedEpisodes,
            events: mergedEvents,
            locations: mergedLocations
        ).validatingIdentities()
    }
}
