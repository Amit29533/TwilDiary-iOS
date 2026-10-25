#if DEBUG
import Foundation
import TwilDiaryCore

/// In-memory counterpart for the existing watch/Undo contracts. No transport exists here.
@MainActor final class FixtureWatchHistory {
    struct Operation: Equatable {
        let title: String; let episode: String?; let date: String?; let rewatch: Bool; let result: String
    }
    struct Update {
        let workspace: Workspace
        let response: [String: Any]
        let operations: [String: Operation]
    }
    private var operations: [String: Operation] = [:]
    private let stamp = "2026-10-23T12:00:00.000Z"

    func prepare(_ original: Workspace, route: String, method: String, body: [String: Any]) throws -> Update? {
        let parts = route.split(separator: "/").map(String.init)
        let logging = method == "POST" && parts.count == 4 && Array(parts.prefix(2)) == ["api", "titles"] && parts[3] == "watches"
        let changing = method == "PATCH" && parts.count == 3 && Array(parts.prefix(2)) == ["api", "watch-events"]
        guard logging || changing else { return nil }
        var titles = try rows(original.titles), events = try rows(original.events), receipts = operations
        let eventID: String, added: Bool
        let titleID: String
        var changed = false, removing = false
        if logging {
            titleID = parts[2]
            guard let title = original.activeTitles.first(where: { $0.id == titleID }) else { throw APIError.rejected(404, "This title is not in your library") }
            guard Set(body.keys).isSubset(of: ["operationId", "episodeId", "watchedAt", "rewatch"]),
                  let operation = body["operationId"] as? String, operation.range(of: #"^[a-zA-Z0-9-]{1,100}$"#, options: .regularExpression) != nil,
                  body["episodeId"] is NSNull || body["episodeId"] is String,
                  body["rewatch"] == nil || body["rewatch"] is Bool else { throw APIError.rejected(400, "Invalid watch input") }
            let episode = body["episodeId"] as? String, rewatch = body["rewatch"] as? Bool ?? false
            let date = try timestamp(body["watchedAt"])
            guard title.isSeries == (episode != nil), episode == nil || original.episodes.contains(where: { $0.id == episode && $0.titleId == titleID }) else { throw APIError.rejected(400, "Choose an episode for this series and no episode for a movie") }
            if let prior = receipts[operation] {
                guard prior.title == titleID, prior.episode == episode, prior.date == date, prior.rewatch == rewatch else { throw APIError.rejected(409, "This operation identity belongs to a different watch") }
                eventID = prior.result; added = false
            } else if !rewatch, let prior = original.events.filter({ $0.titleId == titleID && $0.episodeId == episode && $0.revokedAt == nil }).sorted(by: { $0.recordedAt == $1.recordedAt ? $0.id > $1.id : $0.recordedAt > $1.recordedAt }).first {
                eventID = prior.id; added = false
                receipts[operation] = Operation(title: titleID, episode: episode, date: date, rewatch: rewatch, result: prior.id)
            } else {
                eventID = UUID().uuidString; added = true; changed = true
                let recordedAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(DiaryDate.parse(stamp)!.addingTimeInterval(Double(original.events.count + 1) / 1000))
                events.append(["id": eventID, "operationId": operation, "titleId": titleID, "episodeId": episode as Any? ?? NSNull(), "watchedAt": date as Any? ?? NSNull(), "recordedAt": recordedAt, "revokedAt": NSNull(), "origin": "manual", "version": 1])
                receipts[operation] = Operation(title: titleID, episode: episode, date: date, rewatch: rewatch, result: eventID)
            }
        } else {
            eventID = parts[2]; added = false
            guard let index = events.firstIndex(where: { $0["id"] as? String == eventID }), let title = events[index]["titleId"] as? String,
                  original.activeTitles.contains(where: { $0.id == title }), let expected = body["expectedVersion"] as? Int, expected > 0,
                  let action = body["action"] as? String, ["revoke", "restore"].contains(action), Set(body.keys) == ["expectedVersion", "action"] else { throw APIError.rejected(409, "This watch is no longer available") }
            titleID = title; removing = action == "revoke"
            let revoked = events[index]["revokedAt"] is String, version = events[index]["version"] as? Int ?? 1
            if (removing && revoked) || (!removing && !revoked && version == expected + 1) { }
            else {
                guard version == expected, removing || revoked else { throw APIError.rejected(409, "This watch changed after the action you are undoing") }
                if removing { events[index]["revokedAt"] = stamp } else { events[index]["revokedAt"] = NSNull() }
                events[index]["version"] = version + 1; changed = true
            }
        }
        guard let index = titles.firstIndex(where: { $0["id"] as? String == titleID }), let event = events.first(where: { $0["id"] as? String == eventID }) else { throw APIError.rejected(409, "Watch result is no longer available") }
        if changed, !removing || ["watching", "completed"].contains(titles[index]["status"] as? String ?? "") {
            let title = original.titles.first { $0.id == titleID }!
            let active = events.filter { $0["titleId"] as? String == titleID && !($0["revokedAt"] is String) }
            let regular = original.episodes.filter { $0.titleId == titleID && $0.season > 0 }
            let watched = Set(active.compactMap { $0["episodeId"] as? String })
            let seasons = (title.seasons ?? []).filter { $0.number > 0 }
            let loaded = !seasons.isEmpty && seasons.allSatisfy { season in season.expectedEpisodes.map { expected in regular.filter { $0.season == season.number }.count >= expected } ?? false }
            let complete = title.isSeries ? (!regular.isEmpty && loaded && regular.allSatisfy { watched.contains($0.id) }) : active.contains { !($0["episodeId"] is String) }
            let desired = complete ? "completed" : active.isEmpty ? "planned" : "watching"
            if titles[index]["status"] as? String != desired { titles[index]["status"] = desired; titles[index]["version"] = (titles[index]["version"] as? Int ?? 1) + 1 }
        }
        var archive = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        archive["titles"] = titles; archive["events"] = events
        let workspace = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: archive))
        return Update(workspace: workspace, response: ["event": event, "added": added, "title": titles[index]], operations: receipts)
    }
    func commit(_ update: Update) { operations = update.operations }
    func retain(_ titleIDs: Set<String>) { operations = operations.filter { titleIDs.contains($0.value.title) } }
    private func rows<Value: Encodable>(_ value: Value) throws -> [[String: Any]] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [[String: Any]] }
    private func timestamp(_ value: Any?) throws -> String? {
        if value is NSNull { return nil }
        guard let value = value as? String, value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil, let date = DiaryDate.parse(value) else { throw APIError.rejected(400, "Use a watch timestamp or null for an unknown date") }
        return Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }
}
#endif
