import Foundation
import Observation

struct IncomingTraktStatus: Codable, Equatable, Sendable {
    var enabled: Bool
    var checkedAt: String?
    var importedAt: String?
    var error: String?
    var pending: Int
    var review: Int
    var paused: Bool?
    var pausedBy: String?
    var overdue: Bool?
}

@MainActor protocol IncomingTraktServicing {
    func status() async throws -> IncomingTraktStatus
    func configure(enabled: Bool) async throws -> IncomingTraktStatus
}

@MainActor struct LiveIncomingTraktService: IncomingTraktServicing {
    let store: DiaryStore
    func status() async throws -> IncomingTraktStatus { try await store.read("/api/trakt/incoming") }
    func configure(enabled: Bool) async throws -> IncomingTraktStatus {
        try await store.read("/api/trakt/incoming", method: "PUT", body: ["enabled": enabled])
    }
}

@MainActor @Observable final class IncomingTraktController {
    private let service: any IncomingTraktServicing
    private(set) var status: IncomingTraktStatus?
    private(set) var busy = false
    private(set) var error: String?
    init(service: any IncomingTraktServicing) { self.service = service }
    func refresh() async {
        guard !busy, !Task.isCancelled else { return }
        busy = true; defer { busy = false }
        do { status = try await service.status(); error = nil }
        catch is CancellationError { }
        catch { self.error = "Incoming sync couldn’t be checked. Retry when your diary backend is available." }
    }
    func configure(enabled: Bool) async {
        guard !busy, !Task.isCancelled else { return }
        busy = true; defer { busy = false }
        // Only a server acknowledgement changes the toggle. A lost response
        // requires a status refresh; do not pretend that enable/disable succeeded.
        do { status = try await service.configure(enabled: enabled); error = nil }
        catch is CancellationError { }
        catch { self.error = "The incoming sync setting couldn’t be confirmed. Refresh its status before retrying." }
    }
    var health: String? {
        if status?.overdue == true {
            return "Incoming checks haven’t run for over 10 minutes. Turn incoming watches off and on, then check the Worker logs."
        }
        return switch status?.error {
        case "trakt_reconnect_required", "trakt_connection_required": "Reconnect Trakt to resume incoming watches."
        case "trakt_rate_limited", "metadata_rate_limited": "Waiting for the provider’s cooldown. Your watches will retry."
        case "daily_import_budget", "incoming_daily_budget", "database_read_limit", "database_write_limit": "The daily allowance is in use. Incoming watches resume after midnight UTC."
        case .some: "Incoming watches are waiting to retry. Your saved diary is unchanged."
        case .none: nil
        }
    }
    var pauseExplanation: String? {
        guard status?.paused == true else { return nil }
        if status?.pausedBy == "building" {
            return "Paused while a Trakt scan is running. Plays older than seven days when it resumes need a manual scan."
        }
        return "Paused until you finish or cancel the Trakt review. Plays older than seven days when it resumes need a manual scan."
    }
}

@MainActor func makeIncomingTraktService(store: DiaryStore) -> any IncomingTraktServicing {
    #if DEBUG
    if store.isPreview { return PreviewIncomingTraktService() }
    #endif
    return LiveIncomingTraktService(store: store)
}

#if DEBUG
@MainActor private final class PreviewIncomingTraktService: IncomingTraktServicing {
    private var value = IncomingTraktStatus(enabled: false, pending: 0, review: 0)
    func status() async throws -> IncomingTraktStatus { value }
    func configure(enabled: Bool) async throws -> IncomingTraktStatus { value.enabled = enabled; return value }
}
#endif
