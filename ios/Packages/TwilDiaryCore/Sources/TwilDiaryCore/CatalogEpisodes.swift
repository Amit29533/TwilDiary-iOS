import Foundation

public struct CatalogEpisode: Decodable, Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let name: String
    public let overview: String
    public let airedOn: String?
    public let stillPath: String?
    public let communityScore: Double?
    public init(number: Int, name: String, overview: String, airedOn: String?, stillPath: String?, communityScore: Double?) {
        self.number = number; self.name = name; self.overview = overview; self.airedOn = airedOn; self.stillPath = stillPath; self.communityScore = communityScore
    }
}
public struct CatalogEpisodesPage: Decodable, Sendable {
    public let items: [CatalogEpisode]
    public init(items: [CatalogEpisode]) { self.items = items }
}
