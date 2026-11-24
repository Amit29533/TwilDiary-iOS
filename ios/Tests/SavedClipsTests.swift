import XCTest
@testable import TwilDiary

/// Saved clips: reading a clip's words into searches, matching names, ranking guesses, the
/// replies from TMDB, oEmbed and Gemini, and keeping clips on disk.
final class SavedClipsTests: XCTestCase {
    func testCaptionHashtagsBecomeSearchesWithoutTheNoise() {
        let queries = ClipText.queries(caption: "This drama is insane 🔥 who else is watching? #vivant #jdrama #fyp")
        XCTAssertEqual(queries, ["vivant"])
    }

    func testQuotedTitlesTitlesBeforeAYearAndPageTitles() {
        XCTAssertTrue(ClipText.queries(caption: "Just finished “Breaking Bad” and wow").contains("Breaking Bad"))
        XCTAssertTrue(ClipText.queries(caption: "Vivant (2023) is the best drama this year").contains("Vivant"))
        XCTAssertEqual(ClipText.queries(caption: nil, pageTitle: "Vivant (2023) - Official Trailer | TBS").first, "Vivant")
    }

    func testTextOnScreenPrefersTitleCardsOverSubtitles() {
        let queries = ClipText.queries(caption: nil, screenLines: ["Where are you going?", "VIVANT", "I told you already."], limit: 3)
        XCTAssertEqual(queries.first, "VIVANT")
        XCTAssertFalse(queries.contains("Where are you going?"))
    }

    func testHashtagsSplitAtCapitals() {
        XCTAssertEqual(ClipText.spaced("TheBear"), "The Bear")
        XCTAssertEqual(ClipText.spaced("breaking_bad"), "breaking bad")
        XCTAssertEqual(ClipText.spaced("breakingbad"), "breakingbad")
    }

    func testNamesFitIgnoringSpacesCaseAndSubtitles() {
        XCTAssertEqual(ClipText.fit(query: "breakingbad", name: "Breaking Bad"), 1)
        XCTAssertEqual(ClipText.fit(query: "The Bear", name: "the bear"), 1)
        XCTAssertEqual(ClipText.fit(query: "Frieren", name: "Frieren: Beyond Journey's End"), 0.8)
        XCTAssertEqual(ClipText.fit(query: "Vivant", name: "Severance"), 0)
        XCTAssertEqual(ClipText.fit(query: "Up", name: "Up"), 0.6)
    }

    func testSourcesFromLinks() {
        XCTAssertEqual(ClipText.source(of: "https://www.tiktok.com/@a/video/123"), "TikTok")
        XCTAssertEqual(ClipText.source(of: "https://youtu.be/abc"), "YouTube")
        XCTAssertEqual(ClipText.source(of: "https://www.instagram.com/reel/xyz/"), "Instagram")
        XCTAssertEqual(ClipText.source(of: "https://example.org/clip"), "a website")
        XCTAssertNil(ClipText.source(of: nil))
    }

    private func guess(_ id: Int, _ confidence: Double) -> SavedClip.Candidate {
        .init(tmdbID: id, tv: true, name: "Show \(id)", year: 2023, posterPath: nil, confidence: confidence)
    }

    func testTheSameTitleFoundTwiceIsMoreSure() {
        let merged = ClipRanking.merged([guess(1, 0.6), guess(2, 0.7), guess(1, 0.5)])
        XCTAssertEqual(merged.map(\.tmdbID), [1, 2])
        XCTAssertEqual(merged[0].confidence, 0.8, accuracy: 0.0001)
    }

    func testOnlyASureAndClearLeaderNeedsNoPick() {
        XCTAssertEqual(ClipRanking.state(for: [guess(1, 0.9), guess(2, 0.4)]), .identified)
        XCTAssertEqual(ClipRanking.state(for: [guess(1, 0.9), guess(2, 0.7)]), .needsPick)
        XCTAssertEqual(ClipRanking.state(for: [guess(1, 0.6)]), .needsPick)
        XCTAssertEqual(ClipRanking.state(for: []), .notFound)
    }

    func testTMDBResultsKeepMoviesAndShowsWhoseNamesFit() throws {
        let reply = """
        {"results":[
          {"media_type":"person","id":9,"name":"Vivant Person"},
          {"media_type":"tv","id":215103,"name":"VIVANT","original_name":"VIVANT","first_air_date":"2023-07-16","vote_count":120,"poster_path":"/v.jpg"},
          {"media_type":"movie","id":5,"title":"Something Else","release_date":"2001-01-01","vote_count":900}
        ]}
        """
        let found = ClipTMDB.candidates(fromSearch: Data(reply.utf8), query: "vivant")
        XCTAssertEqual(found.count, 1)
        let show = try XCTUnwrap(found.first)
        XCTAssertEqual(show.tmdbID, 215103); XCTAssertTrue(show.tv); XCTAssertEqual(show.year, 2023); XCTAssertEqual(show.posterPath, "/v.jpg")
        XCTAssertGreaterThan(show.confidence, 0.75)
    }

    func testOEmbedRepliesGiveCaptionAccountAndThumbnail() throws {
        let tiktok = #"{"title":"This drama is insane #vivant","author_unique_id":"jdrama.clips","author_name":"JDrama Clips","thumbnail_url":"https://p16.example/t.jpg"}"#
        let post = try XCTUnwrap(ClipLinks.parse(Data(tiktok.utf8)))
        XCTAssertEqual(post.title, "This drama is insane #vivant")
        XCTAssertEqual(post.author, "@jdrama.clips")
        XCTAssertEqual(post.thumbnail?.absoluteString, "https://p16.example/t.jpg")
    }

    func testGeminiGuessesDecodeEvenInsideAFence() {
        let text = "```json\n[{\"title\":\"Taxi Driver\",\"year\":1976,\"type\":\"movie\",\"confidence\":0.81},{\"title\":\"The Corruptor\",\"type\":\"movie\",\"confidence\":0.04}]\n```"
        let guesses = ClipGemini.decode(text)
        XCTAssertEqual(guesses.map(\.title), ["Taxi Driver", "The Corruptor"])
        XCTAssertEqual(guesses.first?.year, 1976)
        XCTAssertTrue(ClipGemini.decode("not json").isEmpty)
    }

    func testClipsAreKeptOnDiskNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clips-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var older = SavedClip(kind: .link, url: "https://youtu.be/a", source: "YouTube")
        older.created = Date(timeIntervalSince1970: 1_700_000_000)   // November 2023
        let newer = SavedClip(kind: .text, text: "#vivant")
        XCTAssertTrue(ClipStore.add(older, to: folder))
        XCTAssertTrue(ClipStore.add(newer, to: folder))
        let loaded = ClipStore.load(from: folder)
        XCTAssertEqual(loaded.map(\.id), [newer.id, older.id])
        XCTAssertEqual(loaded.last?.url, "https://youtu.be/a")
    }

    func testARenamedAppGroupIsReadFromTheSigningProfile() {
        // A signing profile is a signed plist: binary bytes around the XML.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Entitlements</key><dict>\
        <key>com.apple.security.application-groups</key><array><string>group.com.amit29533.TwilDiary.ABCDE12345</string></array>\
        </dict></dict></plist>
        """
        let profile = Data([0x30, 0x82, 0x01]) + Data(xml.utf8) + Data([0x00, 0xA0])
        XCTAssertEqual(ClipStore.appGroups(inProfile: profile), ["group.com.amit29533.TwilDiary.ABCDE12345"])
        XCTAssertTrue(ClipStore.appGroups(inProfile: Data("no plist".utf8)).isEmpty)
        XCTAssertEqual(ClipStore.groups.last, ClipStore.group)
    }

    func testPastedTextGivesItsLink() {
        XCTAssertEqual(ClipInbox.firstLink(in: "watch this https://www.tiktok.com/@a/video/1 so good"), "https://www.tiktok.com/@a/video/1")
        XCTAssertNil(ClipInbox.firstLink(in: "no link here"))
    }
}
