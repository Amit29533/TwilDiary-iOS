#if DEBUG
import Foundation
import TwilDiaryCore

/// Isolated simulator provider. No HTTP requests or real-account changes are possible here.
@MainActor final class FixtureTraktService: TraktServicing {
    private var connection: TraktStatus
    private let unavailable: Bool
    init(scenario: String = "connected") {
        unavailable = scenario == "unavailable"
        let statusURL = Bundle.main.url(forResource: "trakt-status", withExtension: "json")!
        connection = try! JSONDecoder().decode(TraktStatus.self, from: Data(contentsOf: statusURL))
        if scenario == "disconnected" { connection = TraktStatus(configured: true, connected: false) }
        else if scenario == "reconnect" { connection = TraktStatus(configured: true, connected: true, username: "reference-user", needsReconnect: true) }
    }
    func status() async throws -> TraktStatus {
        if unavailable { throw APIError.message("The connection is temporarily unavailable. Try again.") }
        return connection
    }
    func disconnect() async throws { connection.connected = false }
}
#endif

@MainActor func makeTraktService(store: DiaryStore) -> any TraktServicing {
    #if DEBUG
    if store.isPreview {
        let prefix = "--ui-trakt="
        let scenario = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? "connected"
        return FixtureTraktService(scenario: scenario)
    }
    #endif
    return LiveTraktService(store: store)
}
