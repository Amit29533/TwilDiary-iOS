import XCTest
@testable import TwilDiary

final class WikidataPeopleTests: XCTestCase {
    func testQueryAsksForTheOtherServicesIDOfOnePerson() throws {
        let url = try XCTUnwrap(WikidataPeople.url(from: "P11227", to: "P4985", id: 116517))
        XCTAssertEqual(url.host, "query.wikidata.org")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "query" }?.value, "SELECT ?v WHERE { ?p wdt:P11227 \"116517\" ; wdt:P4985 ?v } LIMIT 3")
        XCTAssertEqual(items.first { $0.name == "format" }?.value, "json")
    }
    func testOnlyASingleUnambiguousLinkIsUsed() {
        func reply(_ values: [String]) -> Data {
            let rows = values.map { "{\"v\":{\"type\":\"literal\",\"value\":\"\($0)\"}}" }.joined(separator: ",")
            return Data("{\"head\":{\"vars\":[\"v\"]},\"results\":{\"bindings\":[\(rows)]}}".utf8)
        }
        XCTAssertEqual(WikidataPeople.single(reply(["1325034"])), 1325034)
        XCTAssertEqual(WikidataPeople.single(reply(["1325034", "1325034"])), 1325034, "the same id twice is one link")
        XCTAssertNil(WikidataPeople.single(reply(["1325034", "99"])), "two people: better none than wrong")
        XCTAssertNil(WikidataPeople.single(reply([])))
        XCTAssertNil(WikidataPeople.single(reply(["nm123"])))
        XCTAssertNil(WikidataPeople.single(Data("<html>".utf8)))
    }
}
