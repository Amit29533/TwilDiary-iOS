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

    func testAKeptBackupIsNeverTakenForTheBackup() {
        XCTAssertNotEqual(GoogleDrive.copyName("2026-11-22"), GoogleDrive.fileName)
        XCTAssertGreaterThan(GoogleDrive.copyName("2026-11-22"), GoogleDrive.copyName("2026-11-21"), "newest first by name")
    }
}
