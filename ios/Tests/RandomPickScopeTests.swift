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
    func testTheAddShortcutOpensUniversalSearchWithoutResettingLibrary() {
        let router = AppRouter()
        router.library("planned")
        let revision = router.libraryRevision
        router.library("add")
        XCTAssertEqual(router.selectedTab, .search)
        XCTAssertEqual(router.libraryShortcut, "planned")
        XCTAssertEqual(router.libraryRevision, revision)
        router.library("add")
        XCTAssertEqual(router.selectedTab, .search)
        XCTAssertEqual(router.libraryRevision, revision)
        XCTAssertEqual(router.paths[.search]?.count, 0)
    }
    func testLibraryShortcutsStillStartUniqueLibraryTransitions() {
        let router = AppRouter()
        router.library("planned")
        XCTAssertEqual(router.selectedTab, .library)
        XCTAssertEqual(router.libraryShortcut, "planned")
        XCTAssertEqual(router.libraryRevision, 1)
        router.library("planned")
        XCTAssertEqual(router.libraryRevision, 2)
    }
}
