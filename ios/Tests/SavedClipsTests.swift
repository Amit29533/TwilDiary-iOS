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

    func testReelCaptionAndPreviewProvideTitleClues() {
        XCTAssertEqual(ClipText.queries(caption: "Control Z"), ["Control Z"])
        XCTAssertEqual(ClipText.queries(caption: "Show: Breaking Bad #edit").first, "Breaking Bad")
        XCTAssertTrue(ClipText.queries(caption: nil, pageTitle: "Watch this scene #TheBear #fyp").contains("The Bear"))
        XCTAssertFalse(ClipLinks.isInstagramPost(URL(string: "https://instagram.com.example.org/reel/123")!))
        XCTAssertTrue(ClipLinks.isInstagramPost(URL(string: "https://www.instagram.com/reel/123")!))
    }

    func testReelWithSeriesYearRangeGivesCleanTitle() {
        let caption = "Epicutz Editz on Instagram: Interesting Fact\n\n💖 Young Lady and Gentleman (2021–2022)\n\nThis heartwarming Korean drama follows…"
        XCTAssertEqual(ClipText.queries(caption: nil, pageTitle: caption).first, "Young Lady and Gentleman")
    }

    func testPublicReelURLValidation() throws {
        let url = try XCTUnwrap(URL(string: "https://www.instagram.com/reel/DZVDZkEzSHm/?igsh=example"))
        XCTAssertEqual(PublicReel.shortcode(url), "DZVDZkEzSHm")
        XCTAssertNil(PublicReel.shortcode(try XCTUnwrap(URL(string: "https://www.instagram.com/accounts/login/"))))
        XCTAssertNil(PublicReel.mediaURL("https://cdninstagram.com.example.org/reel.mp4"))
        XCTAssertNotNil(PublicReel.mediaURL("https://video.cdninstagram.com/reel.mp4"))
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

    func testSharedURLWinsOverCaptionRegardlessOfProviderOrder() throws {
        let reel = try XCTUnwrap(URL(string: "https://www.instagram.com/reel/example/"))
        let promo = "https://example.com/promo"
        var input = ClipShareInput()
        input.add(text: "Visit " + promo)
        input.add(url: URL(fileURLWithPath: "/temporary/movie"))
        XCTAssertEqual(input.resolved().0?.absoluteString, promo)
        input.add(url: reel)
        input.add(text: reel.absoluteString)
        XCTAssertEqual(input.resolved().0, reel)
        XCTAssertEqual(input.resolved().1, "Visit " + promo)
    }

    func testConcurrentAddsKeepAllClipsAndStaleUpdatesCannotResurrectDeletes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = (0..<16).map { SavedClip(kind: .text, text: "clip " + String($0)) }
        DispatchQueue.concurrentPerform(iterations: input.count) { i in
            XCTAssertTrue(ClipStore.add(input[i], to: folder))
        }
        let saved = ClipStore.load(from: folder)
        XCTAssertEqual(Set(saved.map(\.id)), Set(input.map(\.id)))
        let old = try XCTUnwrap(saved.first)
        var updated = old
        updated.state = .identifying
        try ClipStore.replace(old, with: updated, in: folder)
        XCTAssertThrowsError(try ClipStore.replace(old, with: updated, in: folder))
        try ClipStore.remove(old.id, in: folder)
        XCTAssertThrowsError(try ClipStore.replace(updated, with: old, in: folder))
    }

    @MainActor func testRetryRunsAfterAnotherClipAlreadyStarted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var first = SavedClip(kind: .text, text: "First")
        first.created = Date(timeIntervalSince1970: 1000)
        var second = SavedClip(kind: .text, text: "Second")
        second.created = Date(timeIntervalSince1970: 500)
        XCTAssertTrue(ClipStore.add(first, to: folder))
        XCTAssertTrue(ClipStore.add(second, to: folder))
        var pauseSecond = true
        var release: CheckedContinuation<Void, Never>?
        var calls: [UUID] = []
        let inbox = ClipInbox(folder: folder) { clip, _ in
            calls.append(clip.id)
            if clip.id == second.id, pauseSecond {
                await withCheckedContinuation { release = $0 }
            }
            var result = clip
            result.state = .notFound
            return result
        }
        let store = DiaryStore()
        let processing = Task { await inbox.process(store: store) }
        let startDeadline = ContinuousClock.now + .seconds(5)
        while release == nil, ContinuousClock.now < startDeadline { await Task.yield() }
        pauseSecond = false
        guard let release else {
            XCTFail("The worker did not reach the second clip")
            return
        }
        // Queue the retry before the suspended worker gets to resume.
        let retry = Task { await inbox.retry(first.id, store: store) }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, inbox.clips.first(where: { $0.id == first.id })?.state == .notFound {
            await Task.yield()
        }
        XCTAssertEqual(inbox.clips.first(where: { $0.id == first.id })?.state, .waiting)
        release.resume()
        await processing.value
        await retry.value
        XCTAssertEqual(calls, [first.id, second.id, first.id])
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

    func testEvidenceStaysWithTheFailedReelAndQueuesItAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picked = folder.appendingPathComponent("picked.jpg")
        try Data([1, 2, 3]).write(to: picked)
        var reel = SavedClip(kind: .link, url: "https://www.instagram.com/reel/example/", source: "Instagram")
        reel.state = .notFound
        reel.attempts = 3
        XCTAssertEqual(reel.evidenceSummary, "Link only")
        XCTAssertTrue(ClipStore.add(reel, to: folder))
        try ClipStore.attach(picked, video: false, to: reel.id, in: folder)
        let clips = ClipStore.load(from: folder)
        XCTAssertEqual(clips.count, 1)
        let updated = try XCTUnwrap(clips.first)
        XCTAssertEqual(updated.id, reel.id)
        XCTAssertEqual(updated.url, reel.url)
        XCTAssertEqual(updated.state, .waiting)
        XCTAssertEqual(updated.attempts, 0)
        let evidence = try XCTUnwrap(updated.attachments?.first)
        let url = folder.appendingPathComponent(evidence.file)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        // A second picker returning after a retry started must leave no unattached file.
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertThrowsError(try ClipStore.attach(picked, video: true, to: reel.id, in: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before)
        ClipStore.removeFiles(of: updated, in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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

    // The owner's reel (instagram.com/reel/DNLcqNKJEdf), as its public page titles and describes it.
    private let reelTitle = #"Sulpho on Instagram: ""Where it all began" - My Sassy Girl (2001) | Edit | Lord Huron - The Night We Met""#
    private let reelDescription = #"168K likes, 262 comments - sulpho.96 on August 10, 2025: ""Where it all began" - My Sassy Girl (2001) | Edit | Lord Huron - The Night We Met""#

    func testInstagramWrappersGiveTheCaptionAndTheAccount() {
        let caption = #""Where it all began" - My Sassy Girl (2001) | Edit | Lord Huron - The Night We Met"#
        XCTAssertEqual(ClipText.unwrap(reelTitle).caption, caption)
        XCTAssertNil(ClipText.unwrap(reelTitle).author)
        XCTAssertEqual(ClipText.unwrap(reelDescription).caption, caption)
        XCTAssertEqual(ClipText.unwrap(reelDescription).author, "@sulpho.96")
        XCTAssertEqual(ClipText.unwrap("Vivant (2023) - Official Trailer").caption, "Vivant (2023) - Official Trailer")
    }

    func testATitleBeforeItsYearInAPartOfTheCaptionComesFirstWithItsYear() throws {
        let searches = ClipText.searches(caption: nil, pageTitle: reelTitle)
        let first = try XCTUnwrap(searches.first)
        XCTAssertEqual(first.text, "My Sassy Girl"); XCTAssertEqual(first.year, 2001); XCTAssertEqual(first.weight, 1)
        // The tagline in quotes is still tried, for less.
        let tagline = try XCTUnwrap(searches.first { $0.text == "Where it all began" })
        XCTAssertLessThan(tagline.weight, 1)
        XCTAssertFalse(searches.contains { $0.text.contains("Instagram") || $0.text.contains("Sulpho") })
        // A year range stays one part: "(2021–2022)".
        XCTAssertEqual(ClipText.searches(caption: "Young Lady and Gentleman (2021–2022) | Edit").first?.year, 2021)
    }

    func testAYearPicksBetweenTitlesOfTheSameName() throws {
        let reply = """
        {"results":[
          {"media_type":"movie","id":11178,"title":"My Sassy Girl","release_date":"2001-07-27","vote_count":700,"poster_path":"/k.jpg"},
          {"media_type":"movie","id":13692,"title":"My Sassy Girl","release_date":"2008-08-25","vote_count":300,"poster_path":"/u.jpg"}
        ]}
        """
        let ranked = ClipRanking.merged(ClipTMDB.candidates(fromSearch: Data(reply.utf8), query: "My Sassy Girl", year: 2001))
        XCTAssertEqual(ranked.first?.tmdbID, 11178)
        XCTAssertEqual(ClipRanking.state(for: ranked), .identified)
        // Without a year the two are too close to choose between.
        let unsure = ClipRanking.merged(ClipTMDB.candidates(fromSearch: Data(reply.utf8), query: "My Sassy Girl"))
        XCTAssertEqual(ClipRanking.state(for: unsure), .needsPick)
    }

    func testPublicPageTagsAreReadAndUnescaped() throws {
        let html = """
        <html><head><title>Instagram</title>
        <meta property="og:title" content="Sulpho on Instagram: &quot;&quot;Where it all began&quot; - My Sassy Girl (2001)&quot;" />
        <meta name="description" content="168K likes &amp; more" />
        <meta content='https://scontent.cdninstagram.com/v/t51/a.jpg' property='og:image'>
        <meta property="og:video" content="http://insecure.example/v.mp4">
        </head></html>
        """
        let page = ClipPage.parse(html)
        XCTAssertEqual(page.title, #"Sulpho on Instagram: ""Where it all began" - My Sassy Girl (2001)""#)
        XCTAssertEqual(page.description, "168K likes & more")
        XCTAssertEqual(page.image?.host, "scontent.cdninstagram.com")
        XCTAssertNil(page.video, "Only https addresses are kept")
        XCTAssertEqual(ClipPage.decode("it&#39;s &#x2014; &amp;amp;"), "it's — &amp;")
    }
}
