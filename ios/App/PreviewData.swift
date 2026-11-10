import Foundation
import TwilDiaryCore

#if DEBUG
enum PreviewData {
    static var workspace: Workspace {
        let url = Bundle.main.url(forResource: "reference-workspace", withExtension: "json")!
        return try! JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
    }
    #if DEBUG
    static func withLongEpisodeSummaries(_ workspace: Workspace) -> Workspace {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
        var episodes = object["episodes"] as! [[String: Any]]
        for index in episodes.indices where episodes[index]["titleId"] as? String == "again" {
            episodes[index]["overview"] = String(repeating: "This deliberately long episode synopsis checks that expanded grid text stays below the watch control without stretching the artwork or caption. ", count: 4)
        }
        object["episodes"] = episodes
        return try! JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static var longSynopsisWorkspace: Workspace {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
        var titles = object["titles"] as! [[String: Any]]
        if let index = titles.firstIndex(where: { $0["id"] as? String == "frieren" }) {
            let opening = titles[index]["overview"] as? String ?? ""
            titles[index]["overview"] = opening + String(repeating: " A longer fixture passage verifies that expanded text continues below the original opening lines on every phone width.", count: 4)
        }
        object["titles"] = titles
        return try! JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static var upcomingWorkspace: Workspace {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
        var titles = object["titles"] as! [[String: Any]], episodes = object["episodes"] as! [[String: Any]]
        if let index = titles.firstIndex(where: { $0["id"] as? String == "again" }) {
            var seasons = titles[index]["seasons"] as! [[String: Any]]
            seasons.append(["number": 2, "name": "Season 2", "expectedEpisodes": 3, "metadataLoadedAt": "2026-10-23T12:00:00Z", "metadataVersion": 1])
            titles[index]["seasons"] = seasons
        }
        for number in 1...3 {
            episodes.append(["id": "again-upcoming-\(number)", "titleId": "again", "season": 2, "number": number,
                "name": "Future episode \(number)", "overview": "", "airedOn": "2026-10-24", "skipped": false])
        }
        object["titles"] = titles; object["episodes"] = episodes
        return try! JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
    /// Design screenshots (`--ui-design-data`): TMDB ids so Recommended has a seed, and new
    /// episodes airing in the next days so every Home section has something to draw.
    static var designWorkspace: Workspace {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(upcomingWorkspace)) as! [String: Any]
        var titles = object["titles"] as! [[String: Any]], episodes = object["episodes"] as! [[String: Any]]
        for index in titles.indices {
            switch titles[index]["id"] as? String {
            case "again": titles[index]["tmdbId"] = 900002
            case "frieren": titles[index]["tmdbId"] = 209867
            case "night": titles[index]["tmdbId"] = 129818
            case "severance": titles[index]["tmdbId"] = 95396
            default: break
            }
        }
        for index in episodes.indices where (episodes[index]["id"] as? String)?.hasPrefix("again-upcoming-") == true {
            let number = episodes[index]["number"] as? Int ?? 1
            episodes[index]["airedOn"] = "2026-10-2\(6 + number)"
        }
        object["titles"] = titles; object["episodes"] = episodes
        return try! JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
    /// `--ui-many-titles`: a dozen more planned titles, so Library opens as its overview
    /// (five posters, "+N See all", genres) the way a real library does.
    static func withManyTitles(_ workspace: Workspace) -> Workspace {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
        var titles = object["titles"] as! [[String: Any]]
        guard let template = titles.first else { return workspace }
        let names = ["Pseudo Harem", "Oh My Ghost", "Filing for Love", "Following", "Witch Hat Atelier", "Made in Abyss",
                     "The Mentalist", "Doctor Who", "Modern Family", "Obsession", "Dutton Ranch", "A Deliberately Very Long Title That Must Truncate"]
        for (index, name) in names.enumerated() {
            var copy = template
            copy["id"] = "many-\(index)"; copy["name"] = name; copy["status"] = "planned"; copy["year"] = 2015 + index % 12
            copy["communityScore"] = 7.0 + Double(index % 20) / 10; copy["seasons"] = []; copy["poster"] = NSNull(); copy["backdrop"] = NSNull()
            copy.removeValue(forKey: "tmdbId")
            titles.append(copy)
        }
        object["titles"] = titles
        return try! JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
    /// `--ui-old-watches`: a watch dated 1970 and others across many years (like an old import),
    /// so Statistics' per-year chart can be checked with a long, sparse history.
    static func withOldWatches(_ workspace: Workspace) -> Workspace {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
        var events = object["events"] as! [[String: Any]]
        guard let template = events.first else { return workspace }
        let dated: [(String, Int)] = [("1970-01-01", 1), ("2008-06-01", 2), ("2018-03-01", 30), ("2019-05-01", 60), ("2020-07-01", 25),
                                      ("2021-02-01", 90), ("2022-09-01", 40), ("2023-04-01", 120), ("2024-08-01", 70), ("2025-01-01", 55)]
        for (day, count) in dated {
            for index in 0..<count {
                var copy = template
                copy["id"] = "old-\(day)-\(index)"; copy["watchedAt"] = day + String(format: "T%02d:%02d:00.000Z", index % 24, index / 24); copy["recordedAt"] = day + "T00:00:00Z"
                copy["operationId"] = copy["id"]; copy["revokedAt"] = NSNull()
                events.append(copy)
            }
        }
        object["events"] = events
        return (try? JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))) ?? workspace
    }
    /// Explicit identities/scores for profile repair UI checks; never loaded in Release.
    static var profileRepairWorkspace: Workspace {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
        var titles = object["titles"] as! [[String: Any]]
        for index in titles.indices {
            switch titles[index]["id"] as? String {
            case "frieren": titles[index]["tmdbId"] = 209867; titles[index]["communityScore"] = 8.6
            case "again": titles[index]["tmdbId"] = 900002
            case "quiet-orbit": titles[index]["tmdbId"] = 900001
            default: break
            }
        }
        object["titles"] = titles
        return try! JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static var metadataWorkspace: Workspace {
        let value = workspace
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        var titles = object["titles"] as! [[String: Any]]
        if let index = titles.firstIndex(where: { $0["id"] as? String == "again" }) { titles[index]["tmdbId"] = 900002 }
        object["titles"] = titles
        return try! JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }
    #endif
    static func card(_ title: MediaTitle, workspace: Workspace, season: Int? = nil) -> WatchCard {
        let watched = Set(workspace.activeEvents.filter { $0.titleId == title.id }.compactMap(\.episodeId))
        let today = "2026-10-23"
        let selected = season ?? EpisodeSelection.preferredSeason(in: workspace, titleID: title.id, today: today)
        let episodes = workspace.episodes.filter { $0.titleId == title.id && $0.season == selected }.sorted { $0.number < $1.number }
        let next = EpisodeSelection.next(in: workspace, titleID: title.id, today: today, season: selected)
        let prior = workspace.activeEvents.filter { event in event.titleId == title.id && (!title.isSeries || episodes.contains(where: { $0.id == event.episodeId })) }.last
        let previousEpisode = workspace.episodes.first { $0.id == prior?.episodeId }
        let body: [String: Any] = [
            "progress": ["watched": title.isSeries ? episodes.filter { watched.contains($0.id) }.count : (prior == nil ? 0 : 1), "total": title.isSeries ? SeasonProgress.calculate(title: title, workspace: workspace, season: selected).total : 1],
            "season": title.isSeries ? ["number": selected, "name": "Season \(selected)", "metadataLoadedAt": title.seasons?.first(where: { $0.number == selected })?.metadataLoadedAt as Any? ?? NSNull()] as [String: Any] : NSNull(),
            "next": next.map { ["id": $0.id, "number": $0.number] as [String: Any] } as Any? ?? NSNull(),
            "previous": prior.map { ["id": $0.id, "version": $0.version ?? 1, "episodeId": $0.episodeId as Any? ?? NSNull(), "number": previousEpisode?.number as Any? ?? NSNull()] as [String: Any] } as Any? ?? NSNull()
        ]
        return try! JSONDecoder().decode(WatchCard.self, from: JSONSerialization.data(withJSONObject: body))
    }
}
#endif
