import XCTest
@testable import TwilDiary

/// Your own lists: Trakt's list shape as read from /users/me/lists (checked against a public
/// list's reply, 2026-11-19).
final class YourListsTests: XCTestCase {
    func testReadsATraktList() throws {
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"name":"Weekend marathon","description":"Short and good","privacy":"friends","item_count":4,"share_link":"https://trakt.tv/lists/123","ids":{"trakt":123,"slug":"weekend-marathon"}}"#.utf8)) as? [String: Any])
        let list = try XCTUnwrap(YourListsStore.list(row))
        XCTAssertEqual(list.id, 123)
        XCTAssertEqual(list.name, "Weekend marathon")
        XCTAssertEqual(list.privacy, "friends")
        XCTAssertEqual(list.itemCount, 4)
        XCTAssertEqual(list.shareLink, "https://trakt.tv/lists/123")
    }
    func testAListWithoutAnIdIsSkipped() throws {
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"name":"No id","ids":{}}"#.utf8)) as? [String: Any])
        XCTAssertNil(YourListsStore.list(row))
    }
}
