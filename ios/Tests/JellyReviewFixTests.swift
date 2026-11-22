import SwiftUI
import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// The fixes from the review of 22 November 2026.
@MainActor final class JellyReviewFixTests: XCTestCase {
    /// Jellyfin sends a separate subtitle file whole (200); asking for a range of it loaded none on mpv.
    func testOnlySubtitleFilesAreReadWhole() {
        XCTAssertTrue(JellyMPVStream.servedWhole(URL(string: "http://192.168.1.20:8096/Videos/a/b/Subtitles/3/Stream.srt?api_key=k")!))
        XCTAssertTrue(JellyMPVStream.servedWhole(URL(string: "https://example.org/jellyfin/Videos/a/b/Subtitles/0/Stream.ass?api_key=k")!))
        XCTAssertFalse(JellyMPVStream.servedWhole(URL(string: "http://192.168.1.20:8096/Videos/a/stream?static=true&api_key=k")!))
    }

    /// A video keeps the engine set for it; one with none follows the default.
    func testAVideoKeepsItsOwnEngine() {
        let defaults = UserDefaults.standard, keys = ["jellyspace.mpvItems", "jellyspace.appItems", JellyPrefs.engineKey]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        XCTAssertNil(JellyMPVChoice.own("e1"))
        JellyMPVChoice.set("e1", true)
        XCTAssertEqual(JellyMPVChoice.own("e1"), true)
        defaults.set(JellyDecoder.mpv.rawValue, forKey: JellyPrefs.engineKey)
        JellyMPVChoice.set("e2", false)
        XCTAssertEqual(JellyMPVChoice.own("e2"), false, "moved off mpv, which is the default")
        XCTAssertNil(JellyMPVChoice.own("e3"))
        XCTAssertTrue(JellyMPVChoice.isOn("e3"))
    }

    /// One viewing is one watch: marked again sooner than it could have been watched again, it isn't
    /// logged twice. Watched again later, it is.
    func testTheSameViewingIsLoggedOnce() {
        let now = DiaryDate.parse("2026-11-22T14:00:00.000Z")!, episode = 45.0 * 60
        XCTAssertTrue(JellyDiary.sameViewing(["2026-11-22T13:58:00.000Z"], now: now, length: episode))
        XCTAssertTrue(JellyDiary.sameViewing(["2026-11-22T13:52:00Z"], now: now, length: 0), "length unknown: ten minutes")
        XCTAssertFalse(JellyDiary.sameViewing(["2026-11-22T13:10:00.000Z"], now: now, length: episode), "long enough ago to have been watched again")
        XCTAssertFalse(JellyDiary.sameViewing(["2025-11-22T13:58:00.000Z", nil], now: now, length: episode))
        XCTAssertFalse(JellyDiary.sameViewing([], now: now, length: episode))
    }

    func testAFileOfSeveralEpisodesCountsEach() {
        XCTAssertEqual(JellyDiary.numbers(1, to: 2), 1...2)
        XCTAssertEqual(JellyDiary.numbers(5, to: nil), 5...5)
        XCTAssertEqual(JellyDiary.numbers(5, to: 3), 5...5, "a wrong end is ignored")
        XCTAssertEqual(JellyDiary.numbers(1, to: 400), 1...1)
    }

    /// The first time a fresh install meets its saved copy, the lists join rather than one replacing the other.
    func testAFreshInstallJoinsItsSavedList() {
        XCTAssertEqual(PhoneExtras.joined(["new"], ["a", "b", "new"], key: { $0 }), ["new", "a", "b"])
        XCTAssertEqual(PhoneExtras.joined([], ["a"], key: { $0 }), ["a"])
        XCTAssertEqual(PhoneExtras.joined(["a"], [], key: { $0 }), ["a"])
    }

    /// The title an alert opens: said in it, or (one an older build set) in its id.
    func testAnAlertKnowsItsTitle() {
        XCTAssertEqual(AlertOpening.titleID([AlertOpening.key: "tv:1399"], identifier: "anything"), "tv:1399")
        XCTAssertEqual(AlertOpening.titleID([:], identifier: "episode|tv:1399|2026-11-22"), "tv:1399")
        XCTAssertNil(AlertOpening.titleID([:], identifier: "twildiary.checkin.end"))
    }

    // MARK: Settings

    /// A change made before the libraries have loaded leaves their rows where they were.
    func testRowsNotShownKeepTheirPlaces() {
        let saved = ["resume", "latest:a", "latest:b", "genres", "random:a", "themes"]
        let others = ["latest:a", "latest:b", "random:a"]
        XCTAssertEqual(JellyHomeSettingsModel.keeping(others, from: saved, in: ["resume", "genres", "themes"]), saved)
        XCTAssertEqual(JellyHomeSettingsModel.keeping(others, from: saved, in: ["themes", "resume", "genres"]),
                       ["themes", "resume", "latest:a", "latest:b", "genres", "random:a"], "each after what came before it")
        XCTAssertEqual(JellyHomeSettingsModel.keeping(["a", "b"], from: ["a", "b", "c"], in: []), ["a", "b"])
        XCTAssertEqual(JellyHomeSettingsModel.keeping([], from: saved, in: ["genres"]), ["genres"])
    }

    /// Settings go in a backup; who's signed in and this install's own records don't.
    func testABackupCarriesSettingsOnly() {
        for key in ["jellyspace.home.rows", "jellyspace.subtitle.font", "jellyspace.hidden", "customise.tabs", "library.savedFilters", "theme", "use24HourTime"] {
            XCTAssertTrue(SettingsBackup.carries(key), key)
        }
        for key in ["jellyspace.account.user", "jellyspace.deviceID", "jellyspace.userID", "jellyspace.seenUnwatched", "trakt.pendingWrites",
                    "googleDrive.connected", "jellyfinAddress", "phoneOnlyDiary"] {
            XCTAssertFalse(SettingsBackup.carries(key), key)
        }
    }
    func testSettingsComeBackWithoutReplacingWhatsSetHere() throws {
        let name = "settings-backup-test", from = try XCTUnwrap(UserDefaults(suiteName: name + "-from")), to = try XCTUnwrap(UserDefaults(suiteName: name + "-to"))
        defer { from.removePersistentDomain(forName: name + "-from"); to.removePersistentDomain(forName: name + "-to") }
        from.set(30, forKey: "jellyspace.skipSeconds")
        from.set("serif", forKey: "jellyspace.subtitle.font")
        from.set("someone", forKey: "jellyspace.account.user")
        to.set(10, forKey: "jellyspace.skipSeconds")
        SettingsBackup.restore(SettingsBackup.data(from), to: to)
        XCTAssertEqual(to.integer(forKey: "jellyspace.skipSeconds"), 10, "what's set on this phone stays")
        XCTAssertEqual(to.string(forKey: "jellyspace.subtitle.font"), "serif")
        XCTAssertNil(to.string(forKey: "jellyspace.account.user"))
    }

    func testEveryRegionCanBeChosen() {
        XCTAssertTrue(Set(["IN", "US", "PK", "AE", "NZ", "SG"]).isSubset(of: Set(LanguageRegionView.regions)))
        XCTAssertFalse(LanguageRegionView.regions.contains("001"), "the world isn't a country")
    }

    func testATimeFollowsTheClockChosen() {
        let defaults = UserDefaults.standard, before = defaults.object(forKey: "use24HourTime")
        defer { defaults.set(before, forKey: "use24HourTime") }
        let evening = Calendar.current.date(bySettingHour: 21, minute: 5, second: 0, of: .now)!
        defaults.set(true, forKey: "use24HourTime")
        XCTAssertTrue(evening.diaryTime().contains("21"), evening.diaryTime())
    }

    // MARK: Player

    /// AetherEngine rests paused at the very end, with no Up Next: a move there lands a second before.
    func testAMoveToTheEndLeavesTheLastSecondToPlay() {
        XCTAssertEqual(JellyPlayerView.landing(3600, of: 3600), 3599)
        XCTAssertEqual(JellyPlayerView.landing(100, of: 3600), 100)
        XCTAssertEqual(JellyPlayerView.landing(1, of: 1.5), 1, "too short to keep a second of")
        XCTAssertEqual(JellyPlayerView.landing(5, of: 0), 5, "the length isn't known")
    }
    /// Only a file the server has and gives out is the other engine's to try.
    func testWhatTheServerSaysOfAFileThatDidntOpen() {
        XCTAssertEqual(JellyPlayerView.served(206), .here)
        XCTAssertEqual(JellyPlayerView.served(404), .missing)
        XCTAssertEqual(JellyPlayerView.served(401), .refused)
        XCTAssertEqual(JellyPlayerView.served(500), .refused)
    }
    func testCommentariesAndDescriptionsAreKnownByName() {
        XCTAssertTrue(JellyMPV.isCommentary("Director's Commentary"))
        XCTAssertFalse(JellyMPV.isCommentary("English 5.1"))
        XCTAssertTrue(JellyMPV.isDescription("English (Audio Description)"))
        XCTAssertFalse(JellyMPV.isDescription("English"))
    }
    func testSDHIsKnownByItsMarkToo() {
        XCTAssertTrue(JellySubtitlePick.isSDH("English", marked: true))
        XCTAssertTrue(JellySubtitlePick.isSDH("English SDH", marked: false))
        XCTAssertFalse(JellySubtitlePick.isSDH("English", marked: false))
    }
    /// A script's canvas lies over the whole picture, whatever its own shape.
    func testAStyledScriptCoversThePictureWhateverItsShape() {
        let screen = CGSize(width: 800, height: 400)
        let wide = JellyASSLayer.picture(canvas: CGSize(width: 1920, height: 1080), video: CGSize(width: 1920, height: 800), in: screen, fill: .fit, originalSize: .zero)
        XCTAssertEqual(wide.width, 800, accuracy: 0.01)
        XCTAssertEqual(wide.height, 800 * 800 / 1920, accuracy: 0.01)
        let old = JellyASSLayer.picture(canvas: CGSize(width: 640, height: 480), video: CGSize(width: 1280, height: 720), in: screen, fill: .fit, originalSize: .zero)
        XCTAssertEqual(old.width, 400 * 16 / 9, accuracy: 0.01)
        XCTAssertEqual(old.height, 400, accuracy: 0.01)
        let unknown = JellyASSLayer.picture(canvas: CGSize(width: 640, height: 480), video: .zero, in: screen, fill: .fit, originalSize: .zero)
        XCTAssertEqual(unknown.width, 400 * 4 / 3, accuracy: 0.01, "the video's shape isn't known: the script's own")
    }
    /// SRT's own italics and places are kept.
    func testPlainLinesKeepTheirItalicsAndPlace() {
        var italic = AttributedString("Is it?")
        italic.font = Font.body.italic()
        let blocks = JellyPlainLines.blocks([.init(text: "Hello"), .init(text: "EXIT", alignment: 8), .init(text: "Is it?", styled: italic),
                                             .init(text: "Odd", alignment: 12)])
        XCTAssertEqual(blocks.map(\.alignment), [2, 8])
        XCTAssertEqual(blocks.first?.text, "Hello\nIs it?\nOdd")
        XCTAssertEqual(blocks.first?.styled.map { String($0.characters) }, "Hello\nIs it?\nOdd")
        XCTAssertNil(blocks.last?.styled)
        XCTAssertTrue(JellyPlainLines.blocks([]).isEmpty)
        XCTAssertEqual(JellyPlainLines.plain("{\\an8}Top\\Nline"), "Top\nline")
    }

    /// mpv's output is set up again by a shape too close to the picture's own to see.
    func testTheGPUOutputsNudgeIsTooSmallToSee() throws {
        for (width, height, pixel) in [(1920, 1080, 1.0), (3840, 2160, 1.0), (3840, 1608, 1.0), (1080, 1920, 1.0), (720, 576, 64.0 / 45), (720, 480, 8.0 / 9)] {
            let own = Double(width) / Double(height) * pixel
            let first = try XCTUnwrap(JellyMPV.nudged(width: width, height: height, pixel: pixel, step: 1))
            let second = try XCTUnwrap(JellyMPV.nudged(width: width, height: height, pixel: pixel, step: 2))
            XCTAssertGreaterThan(first, own)
            XCTAssertGreaterThan(second, first, "a second try is a change again")
            XCTAssertLessThan(abs(second - own) * 2556, 0.5, "on the longest phone")
        }
        XCTAssertNil(JellyMPV.nudged(width: 0, height: 1080, pixel: 1, step: 1))
        XCTAssertNil(JellyMPV.nudged(width: 1920, height: 1080, pixel: .nan, step: 1))
    }
    func testTheGPUOutputsSizeIsComparedPastRounding() {
        XCTAssertTrue(JellyMPV.same(CGSize(width: 2556, height: 1179), CGSize(width: 2556, height: 1180)))
        XCTAssertFalse(JellyMPV.same(CGSize(width: 1179, height: 2556), CGSize(width: 2556, height: 1179)), "still the upright size")
    }

    // MARK: Elsewhere

    /// A name alone takes a film of the year it should be, not the first of that name.
    func testAnImportedNameIsMatchedByItsYear() {
        let rows: [[String: Any]] = [["id": 1, "release_date": "1984-05-04"], ["id": 2, "release_date": "2021-10-22"], ["id": 3, "release_date": ""]]
        XCTAssertEqual(HistoryImport.pick(rows, year: 2021, movie: true), 2)
        XCTAssertEqual(HistoryImport.pick(rows, year: 1985, movie: true), 1, "a year either side")
        XCTAssertNil(HistoryImport.pick(rows, year: 2005, movie: true))
        XCTAssertEqual(HistoryImport.pick(rows, year: nil, movie: true), 1)
        XCTAssertNil(HistoryImport.pick([], year: nil, movie: false))
    }
    func testGamesAndPodcastsArentImported() {
        let csv = "Const,Your Rating,Date Rated,Title,Title Type,Year\ntt1,8,2024-01-02,A Film,Movie,2020\ntt2,9,2024-01-02,A Game,Video Game,2020\ntt3,7,2024-01-02,A Show,Podcast Series,2020\n"
        XCTAssertEqual(HistoryImport.imdb([(name: "ratings.csv", data: Data(csv.utf8))]).map(\.name), ["A Film"])
    }

    func testAKeptBackupIsNeverTakenForTheBackup() {
        XCTAssertNotEqual(GoogleDrive.copyName("2026-11-22"), GoogleDrive.fileName)
        XCTAssertGreaterThan(GoogleDrive.copyName("2026-11-22"), GoogleDrive.copyName("2026-11-21"), "newest first by name")
    }
}
