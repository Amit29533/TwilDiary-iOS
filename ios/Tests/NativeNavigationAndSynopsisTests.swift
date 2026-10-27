import XCTest
import SwiftUI
@testable import TwilDiary

@MainActor final class NativeNavigationAndSynopsisTests: XCTestCase {
    func testT30LoginNavigationAllowsHTTPSProvidersAndOnlyBlankInternalDocuments() {
        for address in ["https://example.cloudflareaccess.com/login", "https://accounts.google.com/", "about:blank", "about:srcdoc"] {
            XCTAssertTrue(SignInNavigationPolicy.allows(URL(string: address)), address)
        }
        for address in ["http://example.com", "tel:123", "file:///etc/hosts", "data:text/html,test", "javascript:alert(1)", "about:config", "https://user:password@example.com/"] {
            XCTAssertFalse(SignInNavigationPolicy.allows(URL(string: address)), address)
        }
        XCTAssertFalse(SignInNavigationPolicy.allows(nil))
    }
    func testRootTabSwipeUsesTheRequestedDirectionAndStopsAtEitherEnd() {
        // Native paging: the finger moving left reveals the next tab, right the previous one.
        let right = CGSize(width: 150, height: 10), left = CGSize(width: -150, height: 10)
        for (index, tab) in AppTab.allCases.enumerated() {
            XCTAssertEqual(RootTabSwipe.destination(from: tab, translation: left, width: 390), index < 4 ? AppTab.allCases[index + 1] : nil)
            XCTAssertEqual(RootTabSwipe.destination(from: tab, translation: right, width: 390), index > 0 ? AppTab.allCases[index - 1] : nil)
        }
    }
    func testRootTabSwipeRejectsShortVerticalAndInvalidDrags() {
        for drag in [CGSize(width: 40, height: 0), CGSize(width: 100, height: 200), CGSize(width: CGFloat.infinity, height: 0), CGSize(width: 150, height: CGFloat.nan)] {
            XCTAssertNil(RootTabSwipe.destination(from: .library, translation: drag, width: 390))
        }
        XCTAssertNil(RootTabSwipe.destination(from: .library, translation: CGSize(width: 200, height: 0), width: 0))
    }
    func testOnlyRealSidewaysScrollersKeepHorizontalSwipesFromTheTabPager() {
        // Home's carousel keeps its own horizontal drag.
        XCTAssertTrue(RootTabSwipe.isHorizontalScroller(contentWidth: 1400, boundsWidth: 402, bouncesHorizontally: false, bouncesVertically: false))
        XCTAssertTrue(RootTabSwipe.isHorizontalScroller(contentWidth: 402, boundsWidth: 402, bouncesHorizontally: true, bouncesVertically: false))
        // More's list measured 402.5 content in a 402.3 frame; it must not claim the swipe.
        XCTAssertFalse(RootTabSwipe.isHorizontalScroller(contentWidth: 402.5, boundsWidth: 402.3, bouncesHorizontally: false, bouncesVertically: false))
        // A vertically bouncing list never owns horizontal swipes, even a few points too wide.
        XCTAssertFalse(RootTabSwipe.isHorizontalScroller(contentWidth: 410, boundsWidth: 402, bouncesHorizontally: false, bouncesVertically: true))
    }
    func testSwipePastEitherEndBouncesWithABoundedRubberBand() {
        XCTAssertEqual(RootTabSwipe.edgeOffset(0, width: 390), 0)
        let drags = stride(from: CGFloat(0), through: 2000, by: 50).map { RootTabSwipe.edgeOffset($0, width: 390) }
        XCTAssertEqual(drags, drags.sorted(), "The page must keep following the finger")
        for (drag, offset) in zip(stride(from: CGFloat(0), through: 2000, by: 50), drags) {
            XCTAssertLessThanOrEqual(offset, drag, "The page moves slower than the finger")
            XCTAssertLessThan(offset, 390 * 0.25)
        }
        XCTAssertEqual(RootTabSwipe.edgeOffset(-200, width: 390), -RootTabSwipe.edgeOffset(200, width: 390))
        XCTAssertEqual(RootTabSwipe.edgeOffset(.nan, width: 390), 0)
        XCTAssertEqual(RootTabSwipe.edgeOffset(200, width: 0), 0)
    }
    func testCompactHeaderCrossfadesMonotonicallyAndReversesWithoutAThresholdJump() {
        XCTAssertEqual(CompactHeaderTransition.progress(nameBottom: 100), 0)
        XCTAssertEqual(CompactHeaderTransition.progress(nameBottom: -100), 1)
        XCTAssertEqual(CompactHeaderTransition.progress(nameBottom: 8), 0.5)
        let values = stride(from: CGFloat(48), through: -32, by: -4).map { CompactHeaderTransition.progress(nameBottom: $0) }
        XCTAssertEqual(values, values.sorted())
        XCTAssertGreaterThan(Set(values).count, 15, "The hero must fade through intermediate states")
        for (previous, next) in zip(values, values.dropFirst()) { XCTAssertLessThanOrEqual(next - previous, 0.063) }
        XCTAssertEqual(CompactHeaderTransition.progress(nameBottom: .nan), 0)
        XCTAssertEqual(CompactHeaderTransition.progress(nameBottom: .infinity), 0)
    }
    func testDonePopsOnlyTheOwningStackAndKeepsOtherTabHistory() {
        let router = AppRouter()
        router.paths[.home] = NavigationPath([AppDestination.explore, AppDestination.history])
        router.paths[.more] = NavigationPath([AppDestination.files])
        router.selectedTab = .home
        XCTAssertTrue(router.goBack(tab: .more))
        XCTAssertEqual(router.paths[.more]?.count, 0)
        XCTAssertEqual(router.paths[.home]?.count, 2)
        XCTAssertEqual(router.selectedTab, .home)
    }
    func testDoneRemovesExactlyOneRouteAndAnEmptyStackUsesDismissFallback() {
        let router = AppRouter(); router.selectedTab = .library
        var path = NavigationPath(); path.append("again"); path.append(AppDestination.files)
        router.paths[.library] = path
        XCTAssertTrue(router.goBack()); XCTAssertEqual(router.paths[.library]?.count, 1)
        XCTAssertTrue(router.goBack()); XCTAssertEqual(router.paths[.library]?.count, 0)
        XCTAssertFalse(router.goBack()); XCTAssertFalse(router.goBack(tab: .stats))
    }
    func testNestedDoneActionUsesItsOwnStackInsteadOfTheParent() {
        let router = AppRouter(); router.paths[.more] = NavigationPath([AppDestination.files])
        let sheet = AppRouter(); sheet.paths[.home] = NavigationPath([AppDestination.explore, AppDestination.history])
        let action = DiaryBackAction { sheet.goBack(tab: .home) }
        XCTAssertTrue(action.perform()); XCTAssertEqual(sheet.paths[.home]?.count, 1)
        XCTAssertEqual(router.paths[.more]?.count, 1)
    }
    func testShortSynopsisStaysBesideTheCoverWithoutAContinuation() {
        let text = "A short story."
        let parts = SynopsisTextLayout.split(text, width: 200)
        XCTAssertEqual(parts.leading, text); XCTAssertEqual(parts.continuation, "")
    }
    func testSynopsisOverflowPreservesEveryCharacterAndUsesTheMeasuredWidth() {
        let text = String(repeating: "A father gets an unexpected chance to see his family from a new perspective. ", count: 8)
        let narrow = SynopsisTextLayout.split(text, width: 130), wide = SynopsisTextLayout.split(text, width: 250)
        for value in [narrow, wide] {
            XCTAssertFalse(value.leading.isEmpty); XCTAssertFalse(value.continuation.isEmpty)
            XCTAssertEqual(value.leading + value.continuation, text)
        }
        XCTAssertGreaterThan(wide.leading.count, narrow.leading.count)
    }
    func testSynopsisContinuationDoesNotSplitComposedEmojiOrAccentedCharacters() {
        let text = String(repeating: "👩🏽‍🚀 家族 e\u{301} 👨‍👩‍👧‍👦 Wednesday — a story. ", count: 20)
        for width in [CGFloat(80), 130, 200] {
            let parts = SynopsisTextLayout.split(text, width: width)
            XCTAssertEqual(parts.leading + parts.continuation, text)
            XCTAssertEqual(Array(parts.leading) + Array(parts.continuation), Array(text))
            XCTAssertFalse(parts.continuation.isEmpty)
        }
    }
    func testEmptyAndUnmeasuredSynopsisRemainLossless() {
        XCTAssertEqual(SynopsisTextLayout.split("", width: 100), .init(leading: "", continuation: ""))
        XCTAssertEqual(SynopsisTextLayout.split("Not measured", width: 0), .init(leading: "Not measured", continuation: ""))
    }
}
