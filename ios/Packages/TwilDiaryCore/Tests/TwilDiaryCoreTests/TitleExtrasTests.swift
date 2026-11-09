import Foundation
import Testing
@testable import TwilDiaryCore

@Test func titleExtrasDecodeOlderRepliesAndListCompaniesOnce() throws {
    let older = try JSONDecoder().decode(TitleExtras.self, from: Data(#"{"status":"Canceled","certification":"TV-14"}"#.utf8))
    #expect(older.studios.isEmpty && older.networks.isEmpty && older.keywords.isEmpty && older.crew.isEmpty)
    #expect(older.statusLabel == "Canceled" && older.statusIsWarning)
    let json = #"{"status":"Returning Series","certification":null,"studios":[{"id":1,"name":"CloverWorks","logoPath":"/c.png","kind":"studio","country":"JP"},{"id":1,"name":"CloverWorks","logoPath":"/c.png","kind":"studio","country":"JP"}],"networks":[{"id":1,"name":"Tokyo MX","logoPath":null,"kind":"network","country":"JP"}],"keywords":[{"id":2,"name":"anime"}],"crew":[{"id":3,"name":"Keisuke Shinohara","job":"Director","profilePath":null}]}"#
    let extras = try JSONDecoder().decode(TitleExtras.self, from: Data(json.utf8))
    // The same TMDB number as a studio and as a network are two companies; a repeated studio is one.
    #expect(extras.companies.map(\.name) == ["CloverWorks", "Tokyo MX"])
    #expect(extras.statusLabel == "Returning" && !extras.statusIsWarning)
    #expect(extras.crew.first?.job == "Director")
    let movie = TitleExtras(status: "Released", certification: "PG", studios: [], networks: [], keywords: [])
    #expect(movie.statusLabel == nil)
}

@Test func ratingTonesSplitLowMidAndHigh() {
    #expect(RatingTone(score: 3.9) == .low)
    #expect(RatingTone(score: 4.99) == .low)
    #expect(RatingTone(score: 5) == .mid)
    #expect(RatingTone(score: 6.9) == .mid)
    #expect(RatingTone(score: 7) == .high)
    #expect(RatingTone(score: 10) == .high)
}

@Test func episodeRatingSummaryIgnoresInvalidScoresAndPrefersEarlierTies() throws {
    #expect(EpisodeRatingSummary([]) == nil)
    #expect(EpisodeRatingSummary([.init(episode: 1, score: 0), .init(episode: 2, score: .nan)]) == nil)
    let summary = try #require(EpisodeRatingSummary([
        .init(episode: 3, score: 9), .init(episode: 1, score: 8), .init(episode: 2, score: 7.2),
        .init(episode: 4, score: 9), .init(episode: 5, score: 11)
    ]))
    #expect(summary.points.map(\.episode) == [1, 2, 3, 4])
    #expect(abs(summary.average - 8.3) < 0.0001)
    #expect(summary.best == .init(episode: 3, score: 9))
    #expect(summary.lowest == .init(episode: 2, score: 7.2))
    #expect(summary.range == 6...10)
    let flat = try #require(EpisodeRatingSummary([.init(episode: 1, score: 10)]))
    #expect(flat.range.upperBound - flat.range.lowerBound >= 2 && flat.range.upperBound <= 10)
}

@Test func episodeWindowShowsOneBeforeTheNextAndTwoAfter() {
    // 24 episodes, 12 watched: 1–11 fold, 12–15 show, 16–24 fold (the design's layout).
    let middle = EpisodeWindow(count: 24, focus: 12)
    #expect(middle.before == 0..<11 && middle.shown == 11..<15 && middle.after == 15..<24)
    let start = EpisodeWindow(count: 24, focus: 0)
    #expect(start.before.isEmpty && start.shown == 0..<4 && start.after == 4..<24)
    let done = EpisodeWindow(count: 24, focus: nil)
    #expect(done.shown == 20..<24 && done.before == 0..<20 && done.after.isEmpty)
    let short = EpisodeWindow(count: 3, focus: 2)
    #expect(short.before.isEmpty && short.shown == 0..<3 && short.after.isEmpty)
    #expect(EpisodeWindow(count: 0, focus: nil).shown.isEmpty)
}

@Test func tagEmojiPrefersTheMoreSpecificTag() {
    #expect(TagEmoji.symbol(for: "Hand-Drawn Animation") == "✏️")
    #expect(TagEmoji.symbol(for: "Romantic Comedy") == "💕")
    #expect(TagEmoji.symbol(for: "Coming-of-Age") == "🌱")
    #expect(TagEmoji.symbol(for: "anime") == "🌸")
    #expect(TagEmoji.symbol(for: "zzz unknown") == "🏷️")
}

@Test func discoveryFiltersCarryATagCompanyOrNetwork() {
    var filters = DiscoveryFilters(section: .genres)
    filters.type = "tv"; filters.keyword = 210024; filters.label = "Anime"
    let query = filters.query(section: .genres)
    #expect(query["keyword"] == "210024" && query["company"] == nil && query["network"] == nil)
    #expect(filters.error(section: .genres) == nil)
    var company = DiscoveryFilters(section: .genres)
    company.company = 10342
    #expect(company.query(section: .genres)["company"] == "10342")
    #expect(company.resettingFilters().company == 10342)
    #expect(DiscoveryFilters(section: .genres).query(section: .genres)["keyword"] == nil)
}

@Test func sortingCanIgnoreLeadingArticles() {
    #expect(LibraryQuery.sortName("The Bear") == "Bear")
    #expect(LibraryQuery.sortName("A Silent Voice") == "Silent Voice")
    #expect(LibraryQuery.sortName("An Education") == "Education")
    #expect(LibraryQuery.sortName("Anne with an E") == "Anne with an E")
    #expect(LibraryQuery.sortName("The") == "The")
    #expect(LibraryQuery.sortName("Theodosia") == "Theodosia")
}

@Test func recommendationMatchRewardsSharedGenresAndRating() {
    let same = RecommendationMatch.percent(seedGenres: ["Animation", "Comedy"], genres: ["Animation", "Comedy"], rating: 8)
    let half = RecommendationMatch.percent(seedGenres: ["Animation", "Comedy"], genres: ["Animation", "Drama"], rating: 8)
    let none = RecommendationMatch.percent(seedGenres: ["Animation"], genres: ["Western"], rating: 8)
    #expect(same == 97 && same > half && half > none)
    #expect(none >= 50 && same <= 100)
    #expect((76...77).contains(RecommendationMatch.percent(seedGenres: [], genres: nil, rating: nil)))
}
