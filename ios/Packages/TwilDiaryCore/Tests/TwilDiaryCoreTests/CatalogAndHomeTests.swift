import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func publicRatingsNeverSubstituteAnotherSource() throws {
    let unavailable = try JSONDecoder().decode(PublicRating.self, from: Data(#"{"score":null,"state":"unavailable"}"#.utf8))
    let rated = try JSONDecoder().decode(PublicRating.self, from: Data(#"{"score":7.3,"state":"rated"}"#.utf8))
    #expect(CommunityScore.value(tmdb: 8.5, trakt: unavailable, source: .trakt) == nil)
    #expect(CommunityScore.value(tmdb: 8.5, trakt: rated, source: .trakt) == 7.3)
    #expect(CommunityScore.value(tmdb: 8.5, trakt: rated, source: .tmdb) == 8.5)
    #expect(CommunityScore.value(tmdb: .infinity, trakt: nil, source: .tmdb) == nil)
}
@Test func catalogIdentityIncludesKindAndPagingDeduplicates() throws {
    func item(_ kind: String) throws -> CatalogItem {
        try JSONDecoder().decode(CatalogItem.self, from: Data("{\"id\":42,\"mediaType\":\"\(kind)\",\"name\":\"Sample\",\"overview\":\"\"}".utf8))
    }
    let movie = try item("movie"), series = try item("tv")
    #expect(movie.route != series.route)
    #expect(CatalogTools.merging([movie], [movie, series]).count == 2)
    #expect(CatalogTools.image("/image_12.jpg") == "https://image.tmdb.org/t/p/w500/image_12.jpg")
    #expect(CatalogTools.image("//evil.test/a.jpg") == nil)
    #expect(CatalogTools.image("/../private.jpg") == nil)
    #expect(CatalogTools.image("/a.jpg", size: "original") == nil)
}
@Test func weeklySummaryCountsRewatchesButNotFutureOrRevokedEvents() throws {
    var workspace = SampleWorkspace.make()
    let event = try #require(workspace.events.first)
    let now = try #require(DiaryDate.parse("2026-10-23T12:00:00Z"))
    var calendar = DiaryDate.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    calendar.firstWeekday = 2
    let initial = HomeOverview(workspace: workspace, now: now, calendar: calendar)
    workspace.events.append(WatchEvent(id: "intentional-rewatch", operationId: "rewatch-operation", titleId: event.titleId, episodeId: event.episodeId,
                                      watchedAt: event.watchedAt, recordedAt: event.recordedAt, revokedAt: nil, origin: event.origin, version: event.version))
    let repeated = HomeOverview(workspace: workspace, now: now, calendar: calendar)
    #expect(repeated.watches == initial.watches + 1)
    #expect(repeated.minutes == initial.minutes + (workspace.titles.first { $0.id == event.titleId }?.runtimeMinutes ?? 0))
    #expect(repeated.days.count == 7)
    #expect(calendar.component(.weekday, from: repeated.days[0].date) == 2)
    #expect(repeated.days.filter(\.future).allSatisfy { $0.count == 0 })
    #expect(!repeated.planned.contains { $0.id == event.titleId })
}

@Test func posterProgressKeepsUnloadedManifestEpisodesInTheTotal() throws {
    var workspace = SampleWorkspace.make()
    let title = try #require(workspace.titles.first)
    workspace.episodes = workspace.episodes.filter { $0.number <= 2 }
    #expect(LibraryProgress.fraction(title: title, workspace: workspace) == 0.5)
    workspace.events.append(workspace.events[0])
    #expect(LibraryProgress.fraction(title: title, workspace: workspace) == 0.5)
}

@Test func catalogSeasonManifestAndSpoilerSafeEpisodeContractDecode() throws {
    let details = try JSONDecoder().decode(CatalogDetails.self, from: Data(#"{"id":42,"mediaType":"tv","name":"Example","year":null,"overview":"","posterPath":null,"backdropPath":null,"genres":[],"runtimeMinutes":24,"communityScore":8.4,"suggestedCategory":"anime","seasons":[{"number":0,"name":"Specials","expectedEpisodes":2},{"number":1,"name":"Season 1","expectedEpisodes":28}]}"#.utf8))
    #expect(details.seasons?.map(\.number) == [0, 1]); #expect(details.seasons?.last?.expectedEpisodes == 28)
    let page = try JSONDecoder().decode(CatalogEpisodesPage.self, from: Data(#"{"items":[{"number":1,"name":"","overview":"","airedOn":null,"stillPath":null,"communityScore":8.1}],"stale":false}"#.utf8))
    #expect(page.items.first?.name == ""); #expect(page.items.first?.communityScore == 8.1)
}

@Test func archivedCatalogMatchesMustOpenTheRestorePreview() throws {
    let original = try #require(SampleWorkspace.make().titles.first)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object["deletedAt"] = "2026-10-23T00:00:00Z"; object["tmdbId"] = 42
    let title = try JSONDecoder().decode(MediaTitle.self, from: JSONSerialization.data(withJSONObject: object))
    let workspace = Workspace(titles: [title])
    let item = CatalogItem(id: 42, mediaType: title.isSeries ? .tv : .movie, name: title.name, inLibraryId: title.id)
    #expect(CatalogTools.libraryIdentity(item, in: workspace) == nil)
}
