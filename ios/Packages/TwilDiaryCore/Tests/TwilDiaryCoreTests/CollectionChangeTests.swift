import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func collectionRequestsKeepReviewedVersionsAndOnlyEncodeTheChosenAction() throws {
    var title = try #require(SampleWorkspace.make().activeTitles.first)
    let initial = try CollectionRequest(titles: [title], change: .queue(true))
    let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
    #expect(Set(body.keys) == ["action", "items", "queued"])
    #expect(body["queued"] as? Bool == true)
    #expect(initial.items[0].expectedVersion == title.version)
    title.status = "dropped"
    #expect(initial.change == .queue(true), "Watch status is independent of Queue")
    #expect(throws: CollectionRequest.ValidationError.self) { try CollectionRequest(titles: [title, title], change: .trash) }
    #expect(throws: CollectionRequest.ValidationError.self) { try CollectionRequest(titles: [], change: .trash) }
    #expect(throws: CollectionRequest.ValidationError.self) { try CollectionRequest(titles: [title], change: .purge) }
    #expect(throws: CollectionRequest.ValidationError.self) { try CollectionRequest(titles: [title], change: .status("queue")) }
}

@Test func permanentDeletionRequiresArchivedSelectionAndExplicitWireConfirmation() throws {
    let workspace = SampleWorkspace.make()
    var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.titles[0])) as? [String: Any])
    value["deletedAt"] = "2026-10-23T12:00:00Z"
    let archived = try JSONDecoder().decode(MediaTitle.self, from: JSONSerialization.data(withJSONObject: value))
    let request = try CollectionRequest(titles: [archived], change: .purge)
    let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    #expect(body["confirmation"] as? String == "DELETE")
    #expect(throws: CollectionRequest.ValidationError.self) { try CollectionRequest(titles: [archived], change: .favorite(true)) }
}
