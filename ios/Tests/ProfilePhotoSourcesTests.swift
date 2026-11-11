import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor final class ProfilePhotoSourcesTests: XCTestCase {
    func testNamesMatchInEitherOrder() {
        XCTAssertEqual(ProfilePhotoSources.tokens("Tanezaki, Atsumi"), ProfilePhotoSources.tokens("Atsumi Tanezaki"))
        XCTAssertNotEqual(ProfilePhotoSources.tokens("Atsumi Tanezaki"), ProfilePhotoSources.tokens("Atsumi"))
        XCTAssertEqual(ProfilePhotoSources.squashed("Sousou no Frieren"), "sousounofrieren")
    }
    func testJikanAndTMDBPicturesParse() {
        let jikan: [String: Any] = ["data": [["jpg": ["image_url": "https://cdn.myanimelist.net/a.jpg"]], ["jpg": ["image_url": "http://insecure/b.jpg"]]]]
        XCTAssertEqual(ProfilePhotoSources.jikanPictures(jikan, kind: "portrait").map(\.path), ["https://cdn.myanimelist.net/a.jpg"])
        let tmdb: [[String: Any]] = [["file_path": "/abc.jpg", "aspect_ratio": 0.667], ["file_path": "not a path"]]
        XCTAssertEqual(ProfilePhotoSources.tmdbPictures(tmdb, kind: "portrait", aspect: 0.6).map(\.path), ["/abc.jpg"])
    }
    func testMergeKeepsOrderAndDropsRepeats() {
        let a = PersonPhoto(path: "/a.jpg", kind: "portrait", aspectRatio: 1, title: nil)
        let b = PersonPhoto(path: "https://x/b.jpg", kind: "portrait", aspectRatio: 1, title: nil)
        XCTAssertEqual(ProfilePhotoSources.merge([a], [b, a]).map(\.path), ["/a.jpg", "https://x/b.jpg"])
        XCTAssertEqual(b.link(size: "w500"), "https://x/b.jpg")
        XCTAssertEqual(a.link(size: "w500"), "https://image.tmdb.org/t/p/w500/a.jpg")
        XCTAssertEqual(a.originalURL?.absoluteString, "https://image.tmdb.org/t/p/original/a.jpg")
    }
}
