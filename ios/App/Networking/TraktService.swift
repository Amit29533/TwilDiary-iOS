import Foundation
import Observation
import TwilDiaryCore

/// Trakt connected through your server: whether it's connected, and disconnecting it. The old
/// server scan and review (copying the server diary into Trakt) are gone: Trakt holds the diary
/// and the app writes to it directly (TraktDirect).
@MainActor protocol TraktServicing {
    func status() async throws -> TraktStatus
    func disconnect() async throws
}

@MainActor final class LiveTraktService: TraktServicing {
    private weak var owner: DiaryStore?
    init(store: DiaryStore) { owner = store }
    private func requireStore() throws -> DiaryStore {
        guard let owner else { throw CancellationError() }; return owner
    }
    func status() async throws -> TraktStatus { try await requireStore().read("/api/trakt/status") }
    func disconnect() async throws {
        let store = try requireStore()
        store.invalidateDiscovery()
        defer { store.invalidateDiscovery() }
        let _: EmptyResponse = try await store.read("/api/trakt/disconnect", method: "POST", body: [:])
    }
}

@MainActor @Observable final class TraktController {
    private let service: any TraktServicing
    private(set) var status: TraktStatus?
    private(set) var busy = false
    private(set) var loading = false
    var error: String?
    private var refreshID = UUID()
    init(service: any TraktServicing) { self.service = service }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let request = UUID(); refreshID = request; loading = true
        defer { if refreshID == request { loading = false } }
        do {
            let connection = try await service.status()
            guard request == refreshID, !Task.isCancelled else { return }
            status = connection; error = nil
        } catch is CancellationError { }
        catch { if request == refreshID, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func disconnect() async {
        guard !busy else { return }
        busy = true
        var failure: String?
        do { try await service.disconnect() } catch { failure = error.localizedDescription }
        busy = false
        await refresh()
        if let failure { error = failure }
    }
    /// Signed out or another account: nothing from the last one is shown.
    func invalidateSession() {
        refreshID = UUID(); status = nil; error = nil
    }
}
