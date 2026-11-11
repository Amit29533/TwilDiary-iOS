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

    func testFollowsARetiredModelToTheOneGoogleNames() {
        let message = "This model models/gemini-2.5-flash is no longer available to new users. Please update your code to use models/gemini-3.8-flash for the latest features."
        XCTAssertEqual(SemanticSearch.successor(in: message), "gemini-3.8-flash")
        XCTAssertNil(SemanticSearch.successor(in: "Model not found."))
    }

    func testCineMindKeepsTheConversationAndReadsItsAnswer() throws {
        let history = [CineMindView.Message(fromYou: true, text: "Is it worth finishing?"),
                       CineMindView.Message(fromYou: false, text: "Yes."),
                       CineMindView.Message(fromYou: true, text: "Why?")]
        let body = CineMindView.body(system: "context", history: history)
        let turns = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(turns.map { $0["role"] as? String }, ["user", "model", "user"], "the whole chat goes, in order")
        let reply = try CineMindView.decode(#"{"answer":"**Horimiya** is lighter.","titles":[{"title":"Horimiya","year":2021,"type":"tv","why":"Romance|Slice of life"}],"followups":["Something shorter"]}"#)
        XCTAssertEqual(reply.titles.first?.title, "Horimiya")
        XCTAssertEqual(reply.followups, ["Something shorter"])
    }

    func testGroqGetsGeminisQuestionAndAnswersInGeminisShape() throws {
        let body = SemanticSearch.body("a dog and his boy")
        let converted = SemanticSearch.groqMessages(body)
        XCTAssertEqual(converted.messages.first?["role"], "system")
        XCTAssertTrue(converted.messages.first?["content"]?.contains(#"{"items": [...]}"#) == true, "A list answer is asked for inside an object (Groq's JSON mode)")
        XCTAssertEqual(converted.messages.last?["role"], "user")
        XCTAssertEqual(converted.messages.last?["content"], "a dog and his boy")
        let unwrapped = SemanticSearch.groqText(#"{"items":[{"title":"Hachi","year":2009,"type":"movie","why":"A loyal dog"}]}"#, schema: converted.schema)
        let shaped = SemanticSearch.geminiShaped(unwrapped)
        let suggestions = try SemanticSearch.decode(shaped)
        XCTAssertEqual(suggestions.first?.title, "Hachi")
        // CineMind's object answers pass through unchanged.
        let chat = CineMindView.body(system: "Be brief", history: [CineMindView.Message(fromYou: true, text: "Who is in it?")])
        let turns = SemanticSearch.groqMessages(chat)
        XCTAssertEqual(turns.messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(SemanticSearch.groqText(#"{"answer":"Hi"}"#, schema: turns.schema), #"{"answer":"Hi"}"#)
    }
}
