import XCTest
import TwilDiaryCore
@testable import TwilDiary

/// Search by description with Gemini: when it's used, what's asked, and reading the answer.
@MainActor final class SemanticSearchTests: XCTestCase {
    func testAsksForJSONTitlesWithReasons() throws {
        let body = SemanticSearch.body("a boy and his dog")
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        let items = try XCTUnwrap((config["responseSchema"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(items["required"] as? [String], ["title", "type", "why"])
        let text = (((body["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, "a boy and his dog", "only the description is sent")
    }

    func testReadsGeminisAnswer() throws {
        let answer = #"[{"title":"Hachi: A Dog's Tale","year":2009,"type":"movie","why":"A professor and his loyal dog."},{"title":"Old Yeller","type":"movie","why":"A boy and his dog on the frontier."}]"#
        let reply: [String: Any] = ["candidates": [["content": ["parts": [["text": answer]]]]]]
        let suggestions = try SemanticSearch.decode(JSONSerialization.data(withJSONObject: reply))
        XCTAssertEqual(suggestions.map(\.title), ["Hachi: A Dog's Tale", "Old Yeller"])
        XCTAssertEqual(suggestions.first?.year, 2009)
        XCTAssertNil(suggestions.last?.year)
        XCTAssertThrowsError(try SemanticSearch.decode(Data("{}".utf8)), "no answer is said, not shown as nothing found")
    }
}
