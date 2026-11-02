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
        if let csvText = String(data: data, encoding: .utf8),
           !csvText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return try fromExternalCSV(csvText)
        }
        let archive = try JSONDecoder().decode(DiaryExport.self, from: data)
        guard archive.schemaVersion == 1 else {
            throw DiaryExportError.unsupportedSchema(archive.schemaVersion)
        }
        _ = try archive.toWorkspace()
        return archive
    }
    public static func fromExternalCSV(_ csvText: String, now: Date = .now) throws -> DiaryExport {
        let lines = csvText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw DiaryExportError.unsupportedSchema(0)
        }
        func splitCSV(_ line: String) -> [String] {
            var cols: [String] = []
            var cur = ""
            var inQuotes = false
            let chars = Array(line)
            var idx = 0
            while idx < chars.count {
                let ch = chars[idx]
                if ch == "\"" {
                    if inQuotes && idx + 1 < chars.count && chars[idx + 1] == "\"" {
                        cur.append("\"")
                        idx += 1
                    } else {
                        inQuotes.toggle()
                    }
                } else if ch == "," && !inQuotes {
                    cols.append(cur.trimmingCharacters(in: .whitespacesAndNewlines))
                    cur = ""
                } else {
                    cur.append(ch)
                }
                idx += 1
            }
            cols.append(cur.trimmingCharacters(in: .whitespacesAndNewlines))
            return cols
        }
        let headers = splitCSV(lines[0]).map { $0.lowercased() }
        let nameIdx = headers.firstIndex { ["name", "title", "series_title", "original title"].contains($0) }
        guard let nameIdx else { throw DiaryExportError.unsupportedSchema(0) }
        let yearIdx = headers.firstIndex { ["year", "release year"].contains($0) }
        let ratingIdx = headers.firstIndex { ["rating", "your rating", "my_score", "score"].contains($0) }
        let watchedIdx = headers.firstIndex { ["watched date", "date", "date rated", "my_finish_date"].contains($0) }
        let isLetterboxd = headers.contains("letterboxd uri")
        let nowISO = ISO8601DateFormatter().string(from: now)
        var titles: [MediaTitle] = []
        var events: [WatchEvent] = []
        var seen = Set<String>()

        for line in lines.dropFirst().prefix(5000) {
            let cols = splitCSV(line)
            guard nameIdx < cols.count else { continue }
            let rawName = cols[nameIdx]
            guard !rawName.isEmpty else { continue }
            let year = yearIdx.flatMap { $0 < cols.count ? Int(cols[$0]) : nil } ?? 2024
            let slugBase = rawName.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let id = "\(slugBase.isEmpty ? "imported" : String(slugBase.prefix(64)))-\(year)"
            var score: Double? = nil
            if let rIdx = ratingIdx, rIdx < cols.count, let rawVal = Double(cols[rIdx]), rawVal > 0 {
                let scaled = (isLetterboxd && rawVal <= 5.0) ? rawVal * 2.0 : rawVal
                score = min(10.0, max(1.0, (scaled * 10.0).rounded() / 10.0))
            }
            var watchedISO: String? = nil
            if let wIdx = watchedIdx, wIdx < cols.count {
                let rawDate = cols[wIdx]
                if rawDate.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil {
                    watchedISO = "\(rawDate)T20:00:00Z"
                }
            }
            if seen.insert(id).inserted {
                let dict: [String: Any?] = [
                    "id": id,
                    "name": rawName,
                    "category": headers.contains("series_title") ? "anime" : "movie",
                    "year": year,
                    "overview": "",
                    "poster": nil,
                    "backdrop": nil,
                    "communityScore": nil,
                    "tmdbId": nil,
                    "genres": [String](),
                    "tags": [String](),
                    "runtimeMinutes": 110,
                    "status": (watchedISO != nil || score != nil) ? "completed" : "planned",
                    "favorite": false,
                    "queued": false,
                    "score": score,
                    "notes": "",
                    "deletedAt": nil,
                    "version": 1,
                    "seasons": nil
                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: dict.compactMapValues { $0 }),
                   let decodedTitle = try? JSONDecoder().decode(MediaTitle.self, from: jsonData) {
                    titles.append(decodedTitle)
                }
            }
            if let watchedISO {
                let opId = "csv_\(id)_\(watchedISO.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression))"
                events.append(WatchEvent(id: String(opId.prefix(120)), operationId: String(opId.prefix(120)), titleId: id, episodeId: nil, watchedAt: watchedISO, recordedAt: nowISO, origin: "import"))
            }
        }
        return DiaryExport(workspace: Workspace(titles: titles, episodes: [], events: events, locations: []))
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
    /// or standalone local recovery), preferring higher versions and preserving tombstones.
    public func merged(into base: Workspace) throws -> Workspace {
        let base = try base.validatingIdentities()
        let incoming = try toWorkspace()

        // 1. Merge titles by ID, preferring the higher `version` while preserving personal notes/scores when equal.
        var titleByID = Dictionary(uniqueKeysWithValues: base.titles.map { ($0.id, $0) })
        for item in incoming.titles {
            if let existing = titleByID[item.id] {
                let existingVer = existing.version ?? 1
                let incomingVer = item.version ?? 1
                if incomingVer > existingVer {
                    titleByID[item.id] = item
                } else if incomingVer == existingVer {
                    var merged = existing
                    if merged.score == nil, let s = item.score { merged.score = s }
                    if merged.notes.isEmpty, !item.notes.isEmpty { merged.notes = item.notes }
                    if (merged.tags ?? []).isEmpty, let incomingTags = item.tags, !incomingTags.isEmpty {
                        merged.tags = incomingTags
                    }
                    if item.favorite { merged.favorite = true }
                    if item.deletedAt != nil && merged.deletedAt == nil { merged.deletedAt = item.deletedAt }
                    titleByID[item.id] = merged
                }
            } else {
                titleByID[item.id] = item
            }
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
            if let existing = eventByID[ev.id] {
                let existingVer = existing.version ?? 1
                let incomingVer = ev.version ?? 1
                if incomingVer > existingVer || (incomingVer == existingVer && ev.revokedAt != nil && existing.revokedAt == nil) {
                    eventByID[ev.id] = ev
                }
            } else if !seenOperationIDs.contains(ev.operationId) {
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
