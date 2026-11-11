import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Import from Letterboxd, IMDb and TV Time: reading their exports.
final class HistoryImportTests: XCTestCase {
    private func file(_ name: String, _ text: String) -> (name: String, data: Data) { (name, Data(text.utf8)) }

    func testCSVKeepsQuotedCommasQuotesAndLineBreaks() {
        let rows = CSV.rows(Data("\u{FEFF}Name,Year,Note\r\n\"Crouching Tiger, Hidden Dragon\",2000,\"He said \"\"hi\"\"\nthen left\"\r\nHeat,1995,\n".utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"], "Crouching Tiger, Hidden Dragon")
        XCTAssertEqual(rows[0]["note"], "He said \"hi\"\nthen left")
        XCTAssertEqual(rows[1]["year"], "1995")
    }

    func testLetterboxdDiaryRatingsWatchedAndWatchlist() {
        let entries = HistoryImport.letterboxd([
            file("diary.csv", "Date,Name,Year,Letterboxd URI,Rating,Rewatch,Tags,Watched Date\n2024-01-02,Heat,1995,x,4.5,,,2024-01-01\n2024-03-02,Heat,1995,x,,Yes,,2024-03-01\n"),
            file("watched.csv", "Date,Name,Year,Letterboxd URI\n2023-05-05,Heat,1995,x\n2023-06-06,Alien,1979,x\n"),
            file("watchlist.csv", "Date,Name,Year,Letterboxd URI\n2024-02-02,Dune,2021,x\n"),
            file("deleted/diary.csv", "Date,Name,Year,Letterboxd URI,Rating,Rewatch,Tags,Watched Date\n2020-01-01,Gone,2000,x,1,,,2020-01-01\n"),
        ])
        let heat = entries.first { $0.name == "Heat" }
        XCTAssertEqual(heat?.rating, 9, "4.5 stars is 9 of 10")
        XCTAssertEqual(heat?.plays.map(\.watchedAt), ["2024-01-01T12:00:00.000Z", "2024-03-01T12:00:00.000Z"], "dated watches and the rewatch; watched.csv adds none")
        XCTAssertEqual(entries.first { $0.name == "Alien" }?.plays.map(\.watchedAt), ["2023-06-06T12:00:00.000Z"], "watched without a diary entry: the day it was logged")
        XCTAssertEqual(entries.first { $0.name == "Dune" }?.planned, true)
        XCTAssertNil(entries.first { $0.name == "Gone" }, "deleted entries stay out")
    }

    func testIMDbRatingsAndWatchlist() {
        let entries = HistoryImport.imdb([
            file("ratings.csv", "Const,Your Rating,Date Rated,Title,URL,Title Type,IMDb Rating,Runtime (mins),Year\ntt0113277,8,2023-04-01,Heat,x,Movie,8.3,170,1995\ntt0903747,10,2022-01-01,Breaking Bad,x,TV Series,9.5,49,2008\ntt0959621,9,2022-01-01,Pilot,x,TV Episode,9,58,2008\n"),
            file("watchlist.csv", "Position,Const,Created,Modified,Description,Title,URL,Title Type,IMDb Rating,Runtime (mins),Year\n1,tt1160419,2024-01-01,,,Dune,x,Movie,8,155,2021\n"),
        ])
        XCTAssertEqual(entries.count, 3, "episode ratings are left out")
        let heat = entries.first { $0.imdb == "tt0113277" }
        XCTAssertEqual(heat?.rating, 8); XCTAssertEqual(heat?.plays.first?.watchedAt, "2023-04-01T12:00:00.000Z")
        let show = entries.first { $0.imdb == "tt0903747" }
        XCTAssertEqual(show?.kind, .show); XCTAssertEqual(show?.plays.count, 0, "a rated show has no dated watches")
        XCTAssertEqual(entries.first { $0.imdb == "tt1160419" }?.planned, true)
    }

    func testTVTimeEpisodesByShow() {
        let entries = HistoryImport.tvTime([
            file("seen_episode.csv", "episode_id,tv_show_name,episode_season_number,episode_number,created_at,tv_show_id\n1,Lost,1,1,2019-03-02 21:33:12,73739\n2,Lost,1,2,2019-03-03 20:00:00,73739\n3,Lost,1,2,2019-03-04 20:00:00,73739\n"),
        ])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].tvdb, 73739)
        XCTAssertEqual(entries[0].plays.count, 2, "each episode once")
        XCTAssertEqual(entries[0].plays.first?.watchedAt, "2019-03-02T21:33:12.000Z")
    }

    func testZipFromTheExportIsOpened() throws {
        // A stored (uncompressed) ZIP with one CSV, as a minimal export.
        let name = Data("diary.csv".utf8), body = Data("Date,Name,Year\n".utf8)
        func le16(_ value: Int) -> Data { Data([UInt8(value & 0xff), UInt8(value >> 8 & 0xff)]) }
        func le32(_ value: Int) -> Data { le16(value & 0xffff) + le16(value >> 16) }
        let local: [Data] = [le32(0x04034b50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0), le32(body.count), le32(body.count),
                             le16(name.count), le16(0), name, body]
        var zip = local.reduce(Data(), +)
        let directory = zip.count
        let central: [Data] = [le32(0x02014b50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(0), le32(body.count), le32(body.count),
                               le16(name.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(0), name]
        zip += central.reduce(Data(), +)
        let size = zip.count - directory
        let end: [Data] = [le32(0x06054b50), le16(0), le16(0), le16(1), le16(1), le32(size), le32(directory), le16(0)]
        zip += end.reduce(Data(), +)
        let files = HistoryImport.csvFiles([("export.zip", zip)])
        XCTAssertEqual(files.map(\.name), ["diary.csv"])
        XCTAssertEqual(files.first?.data, body)
    }

    func testImportBecomesADiaryWithEpisodes() {
        var show = ImportEntry(kind: .show, name: "Lost", tmdb: 4607)
        show.plays = [ImportPlay(season: 1, episode: 1, watchedAt: "2019-03-02T21:33:12.000Z")]
        var movie = ImportEntry(kind: .movie, name: "Dune", tmdb: 438631)
        movie.planned = true
        let workspace = HistoryImport.workspace([show, movie])
        XCTAssertEqual(workspace.titles.first { $0.id == "tv:4607" }?.status, "watching")
        XCTAssertEqual(workspace.titles.first { $0.id == "movie:438631" }?.status, "planned")
        XCTAssertEqual(workspace.episodes.first?.season, 1)
        XCTAssertEqual(workspace.events.first?.episodeId, workspace.episodes.first?.id)
    }
}
