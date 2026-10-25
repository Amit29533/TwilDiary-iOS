import Foundation
import Testing
@testable import TwilDiaryCore
import TwilDiaryTestSupport

@Test func searchNormalizesCompatibilityTextAndExtractsOnlyTrustedIMDbURLs() {
    #expect(DiarySearchTools.normalize("  Ｆｒｉｅｒｅｎ  ") == "Frieren")
    #expect(DiarySearchTools.normalize("https://www.imdb.com/title/TT1234567/?ref_=test") == "tt1234567")
    #expect(DiarySearchTools.normalize("TT1234567890") == "tt1234567890")
    for invalid in ["https://evil.test/title/tt1234567/", "https://imdb.com.evil.test/title/tt1234567/", "tt123456", "tt12345678901"] { #expect(DiarySearchTools.normalize(invalid) == invalid) }
    #expect(!DiarySearchTools.ready("a")); #expect(!DiarySearchTools.ready("a\nb"))
    #expect(DiarySearchTools.ready(String(repeating: "😀", count: 100)))
    #expect(!DiarySearchTools.ready(String(repeating: "😀", count: 101)))
}

@Test func localSearchRemainsAvailableWithoutOnlineResultsAndDeduplicatesIdentifiedTitles() throws {
    let workspace = SampleWorkspace.make(), title = try #require(SampleWorkspace.make().activeTitles.first)
    let query = DiarySearchTools.normalize("  " + title.name.uppercased() + "  ")
    let local = DiarySearchTools.matches(workspace, query: query)
    #expect(local.contains { $0.id == title.id })
    #expect(DiarySearchTools.merging(local, local).count == local.count)
    #expect(DiarySearchTools.matches(workspace, query: "").isEmpty)
    let partial = try JSONDecoder().decode(DiarySearchPage.self, from: Data(#"{"library":[{"id":"identified","name":"By identity","year":null,"category":"show","posterPath":null}],"online":[],"page":1,"totalPages":0,"onlineError":"Provider temporarily unavailable"}"#.utf8))
    #expect(partial.library.first?.id == "identified"); #expect(partial.library.first?.artwork == nil)
    #expect(DiarySearchTools.merging(local, partial.library).count == local.count + 1)
    #expect(!partial.onlineError.isEmpty)
}
