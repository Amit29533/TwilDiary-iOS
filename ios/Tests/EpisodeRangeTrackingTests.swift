import XCTest
import UIKit
@testable import TwilDiary

@MainActor final class EpisodeRangeTrackingTests: XCTestCase {
    private func slider() -> EpisodeRangeInput.TrackSlider {
        let control = EpisodeRangeInput.TrackSlider(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        control.present(value: 2, maximum: 16, enabled: true, scope: "show:season:1")
        return control
    }
    func testExternalParentValueCannotMoveAnActiveFingerDraft() {
        let control = slider(); var committed: Double?
        control.committed = { committed = $0 }
        XCTAssertTrue(control.beginDrag(at: CGPoint(x: 160, y: 22)))
        XCTAssertEqual(control.value, 8)
        control.present(value: 3, maximum: 16, enabled: true, scope: "show:season:1")
        XCTAssertEqual(control.value, 8); XCTAssertTrue(control.dragActive)
        control.endTracking(nil, with: nil)
        XCTAssertEqual(committed, 8); XCTAssertFalse(control.dragActive)
        control.present(value: 9, maximum: 16, enabled: true, scope: "show:season:1")
        XCTAssertEqual(control.value, 9)
    }
    func testNewSeasonCancelsOldDraftAndItsLateEndCannotCommitToTheNewSeason() async {
        let control = slider(); var cancellations = 0, commits = 0
        control.cancelled = { cancellations += 1 }; control.committed = { _ in commits += 1 }
        control.beginDrag(at: CGPoint(x: 160, y: 22))
        control.present(value: 1, maximum: 16, enabled: true, scope: "show:season:2")
        control.endTracking(nil, with: nil)
        let cancelled = await waitForRegressionCondition({ cancellations == 1 })
        XCTAssertTrue(cancelled)
        XCTAssertEqual(cancellations, 1); XCTAssertEqual(commits, 0)
        XCTAssertEqual(control.value, 1); XCTAssertFalse(control.dragActive)
    }
    func testDisableAndRangeChangeCancelRatherThanReinterpretTheGesture() async {
        for disabled in [false, true] {
            let control = slider(); var cancellations = 0, commits = 0
            control.cancelled = { cancellations += 1 }; control.committed = { _ in commits += 1 }
            control.beginDrag(at: CGPoint(x: 160, y: 22))
            control.present(value: 1, maximum: disabled ? 16 : 10, enabled: !disabled, scope: "show:season:1")
            control.cancelTracking(with: nil); control.endTracking(nil, with: nil)
            let cancelled = await waitForRegressionCondition({ cancellations == 1 })
            XCTAssertTrue(cancelled)
            XCTAssertEqual(cancellations, 1); XCTAssertEqual(commits, 0); XCTAssertEqual(control.value, 1)
        }
    }
    func testCancelledTouchDoesNotCommitAndVoiceOverAdjustmentStillCommitsOnce() {
        let control = slider(); var cancellations = 0, values: [Double] = []
        control.cancelled = { cancellations += 1 }; control.committed = { values.append($0) }
        control.beginDrag(at: CGPoint(x: 160, y: 22)); control.cancelTracking(with: nil)
        control.endTracking(nil, with: nil)
        XCTAssertEqual(cancellations, 1); XCTAssertTrue(values.isEmpty)
        control.present(value: 2, maximum: 16, enabled: true, scope: "show:season:1")
        control.accessibilityIncrement(); XCTAssertEqual(values, [3])
        control.accessibilityDecrement(); XCTAssertEqual(values, [3, 2])
    }
    func testDeferredOldCancellationCannotClearANewFingerDraft() async {
        let control = slider(); var cancellations = 0, committed: Double?
        control.cancelled = { cancellations += 1 }; control.committed = { committed = $0 }
        control.beginDrag(at: CGPoint(x: 160, y: 22))
        control.present(value: 1, maximum: 16, enabled: true, scope: "show:season:2")
        control.beginDrag(at: CGPoint(x: 80, y: 22))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(cancellations, 0); XCTAssertTrue(control.dragActive); XCTAssertEqual(control.value, 4)
        control.endTracking(nil, with: nil); XCTAssertEqual(committed, 4)
    }
}
