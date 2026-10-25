import XCTest
import TwilDiaryCore
import TwilDiaryTestSupport
@testable import TwilDiary

@MainActor final class RandomPickScopeTests: XCTestCase {
    func testAnExplicitEmptyPoolNeverFallsBackToTheWholeCollection() {
        let workspace = SampleWorkspace.make()
        XCTAssertEqual(RandomPickScope(titleIDs: nil).candidates(in: workspace).map(\.id), workspace.titles.map(\.id))
        XCTAssertTrue(RandomPickScope(titleIDs: []).candidates(in: workspace).isEmpty)
        let ids = workspace.titles.prefix(2).map(\.id)
        XCTAssertEqual(RandomPickScope(titleIDs: ids + ["missing"]).candidates(in: workspace).map(\.id), ids)
    }
    func testTheAddShortcutStartsAUniqueLibraryTransition() {
        let router = AppRouter()
        router.library("add")
        XCTAssertEqual(router.selectedTab, .library)
        XCTAssertEqual(router.libraryShortcut, "add")
        XCTAssertEqual(router.libraryRevision, 1)
        router.library("add")
        XCTAssertEqual(router.libraryRevision, 2)
    }
}
