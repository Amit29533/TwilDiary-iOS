import SwiftUI
import TwilDiaryCore

@MainActor @Observable final class DiaryStore {
    var workspace = Workspace()
    var loading = false
    var busy = false
    var needsSignIn = true
    var hasLoadedWorkspace = false
    var error: String?
    var undoLabel: String?
    private var undoAction: (() async throws -> Void)?
    private let api: DiaryAPI
    private var pendingWatches: [String: [String: Any]] = [:]
    private var pendingProgress: [String: [String: Any]] = [:]
    private var pendingRemovals: [String: WatchCard.Previous] = [:]
    let isPreview: Bool
    init(api: DiaryAPI? = nil) {
        self.api = api ?? DiaryAPI()
        #if DEBUG
        isPreview = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        isPreview = false
        #endif
        if isPreview { workspace = PreviewData.workspace; needsSignIn = false; hasLoadedWorkspace = true }
        else { needsSignIn = self.api.credential == nil }
    }
    func connect(_ credential: AccessCredential) async {
        do {
            try await api.authenticate(credential)
            needsSignIn = false; error = nil; await refresh()
        } catch { fail(error) }
    }
    func signOut() {
        api.signOut(); workspace = Workspace(); hasLoadedWorkspace = false; error = nil
        pendingWatches.removeAll(); pendingProgress.removeAll(); pendingRemovals.removeAll(); undoAction = nil; undoLabel = nil
        needsSignIn = true
    }
    func refresh() async {
        guard !isPreview, !loading, !needsSignIn else { return }
        loading = true; defer { loading = false }
        do { try await reload(); error = nil } catch { fail(error) }
    }
    private func reload() async throws {
        // Publish only a complete snapshot. A failed page cannot replace good data with a partial diary.
        let titles = try await api.allPages("titles", as: MediaTitle.self)
        let episodes = try await api.allPages("episodes", as: Episode.self)
        let events = try await api.allPages("events", as: WatchEvent.self)
        let locations = try await api.allPages("locations", as: FileLocation.self)
        workspace = Workspace(titles: titles, episodes: episodes, events: events, locations: locations)
        hasLoadedWorkspace = true
    }
    func title(_ id: String) -> MediaTitle? { workspace.titles.first { $0.id == id } }
    func card(_ title: MediaTitle, season: Int? = nil) async throws -> WatchCard {
        var query = "?day=\(DiaryDate.day())"
        if let season { query += "&season=\(season)" }
        do { return try await api.request("/api/glance/\(title.id)" + query) }
        catch { fail(error); throw error }
    }
    func loadSeason(_ title: MediaTitle, number: Int) async {
        await perform {
            let _: EmptyResponse = try await self.api.request("/api/titles/\(title.id)/seasons/\(number)/metadata", method: "POST")
        }
    }
    func markNext(_ title: MediaTitle, season: Int? = nil) async {
        await perform {
            let key = title.id
            if self.pendingWatches[key] == nil {
                let card = try await self.card(title, season: season)
                if title.isSeries && card.next == nil { throw APIError.message("No aired episode is ready to mark. Load this season’s episodes or choose another season.") }
                self.pendingWatches[key] = ["operationId": UUID().uuidString, "episodeId": card.next?.id as Any? ?? NSNull(), "watchedAt": Date.now.ISO8601Format(), "rewatch": false]
            }
            let operation = self.pendingWatches[key]!
            let result: WatchReceipt
            do { result = try await self.api.request("/api/titles/\(title.id)/watches", method: "POST", body: operation) }
            catch { if Self.definitivelyRejected(error) { self.pendingWatches.removeValue(forKey: key) }; throw error }
            self.pendingWatches.removeValue(forKey: key)
            // Do not undo somebody else's pre-existing watch returned by an idempotent server response.
            if result.added || (result.event.operationId == operation["operationId"] as? String && result.event.version == 1 && result.event.revokedAt == nil) {
                self.undoLabel = "Watch marked"
                self.undoAction = { try await self.changeEvent(result.event, action: "revoke") }
            }
        }
    }
    func removeLatest(_ title: MediaTitle, season: Int? = nil) async {
        await perform {
            if self.pendingRemovals[title.id] == nil {
                let card = try await self.card(title, season: season)
                guard let previous = card.previous else { return }
                self.pendingRemovals[title.id] = previous
            }
            let event = self.pendingRemovals[title.id]!
            let result: EventReceipt
            do { result = try await self.api.request("/api/watch-events/\(event.id)", method: "PATCH", body: ["action": "revoke", "expectedVersion": event.version]) }
            catch { if Self.definitivelyRejected(error) { self.pendingRemovals.removeValue(forKey: title.id) }; throw error }
            self.pendingRemovals.removeValue(forKey: title.id)
            self.undoLabel = "Watch removed"
            self.undoAction = { try await self.changeEvent(result.event, action: "restore") }
        }
    }
    private func changeEvent(_ event: WatchEvent, action: String) async throws {
        let _: EventReceipt = try await api.request("/api/watch-events/\(event.id)", method: "PATCH", body: ["action": action, "expectedVersion": event.version ?? 1])
    }
    func patch(_ title: MediaTitle, values: [String: Any]) async {
        await perform {
            var body = values; body["expectedVersion"] = title.version
            let _: EmptyResponse = try await self.api.request("/api/titles/\(title.id)", method: "PATCH", body: body)
        }
    }
    func setStatus(_ title: MediaTitle, status: String) async {
        if status != "planned" && status != "completed" { await patch(title, values: ["status": status]); return }
        await perform {
            // Completing a series must load the catalogue before the transaction.
            if status == "completed" && title.isSeries {
                for season in title.seasons ?? [] where season.number > 0 && season.metadataLoadedAt == nil {
                    let _: EmptyResponse = try await self.api.request("/api/titles/\(title.id)/seasons/\(season.number)/metadata", method: "POST")
                }
            }
            let key = title.id + ":" + status
            if self.pendingProgress[key] == nil {
                self.pendingProgress[key] = ["operationId": UUID().uuidString, "items": [["id": title.id, "expectedVersion": title.version ?? 1]], "status": status, "watchedAt": Date.now.ISO8601Format(), "today": DiaryDate.day()]
            }
            let receipt: ProgressReceipt
            do { receipt = try await self.api.request("/api/progress/status", method: "POST", body: self.pendingProgress[key]) }
            catch { if Self.definitivelyRejected(error) { self.pendingProgress.removeValue(forKey: key) }; throw error }
            self.pendingProgress.removeValue(forKey: key)
            self.undoLabel = status == "planned" ? "Progress reset" : "Marked completed"
            let undoBody: [String: Any] = ["operationId": UUID().uuidString, "undoOf": receipt.operationId]
            self.undoAction = {
                let _: ProgressReceipt = try await self.api.request("/api/progress/status", method: "POST", body: undoBody)
            }
        }
    }
    func undo() async {
        guard let action = undoAction else { return }
        await perform { try await action(); self.undoAction = nil; self.undoLabel = nil }
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy, !isPreview else { return }
        busy = true; defer { busy = false }
        do { try await action(); try await reload(); error = nil }
        catch { fail(error) }
    }
    private func fail(_ cause: Error) {
        if case APIError.signIn = cause { needsSignIn = true }
        error = cause.localizedDescription
    }
    private static func definitivelyRejected(_ cause: Error) -> Bool {
        guard let apiError = cause as? APIError, case .rejected(let status, _) = apiError else { return false }
        return (400..<500).contains(status) && ![408, 425, 429].contains(status)
    }
    private struct WatchReceipt: Decodable { let event: WatchEvent; let added: Bool }
    private struct EventReceipt: Decodable { let event: WatchEvent }
    private struct ProgressReceipt: Decodable { let operationId: String }
}
