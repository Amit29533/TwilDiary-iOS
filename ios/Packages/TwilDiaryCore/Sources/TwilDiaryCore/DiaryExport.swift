import Foundation

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
}
