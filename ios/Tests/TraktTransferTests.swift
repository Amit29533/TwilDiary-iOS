import XCTest
import TwilDiaryCore
@testable import TwilDiary

@MainActor private final class TransferClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var waits = [TimeInterval]()
    func sleep(_ interval: TimeInterval) async { waits.append(interval); now.addTimeInterval(interval); await Task.yield() }
}
@MainActor private final class TransferService: TraktServicing {
    var snapshot: TraktSync
    var applies = 0
    var steps = 0
    var stepRefusal: Error?
    var reads = 0
    var sequence = [String]()
    var failBefore = false
    var loseReceipt = false
    var neverAvailable = false
    var replaceOnRead = false
    var refusal: Error?
    var statusRefusal: Error?
    var reviewRefusal: Error?
    var statusUnavailable = false
    var connection = TraktStatus(configured: true, connected: true)
    var statusReads = 0
    var holdStatus = false
    var heldStatus: CheckedContinuation<TraktStatus, Never>?
    var holdReview = false
    var heldReview: CheckedContinuation<TraktSync, Never>?
    var hold = false
    var held: CheckedContinuation<TraktSync, Never>?
    init(total: Int) {
        let data = try! JSONSerialization.data(withJSONObject: ["run": ["id": "transfer-run", "state": "review", "stage": "done", "page": 1, "progress": 2000, "retryAfter": 0], "items": [], "counts": ["pending": total, "safe": total, "applied": 0]])
        snapshot = try! JSONDecoder().decode(TraktSync.self, from: data)
    }
    func status() async throws -> TraktStatus {
        statusReads += 1
        if let error = statusRefusal { statusRefusal = nil; throw error }
        if statusUnavailable { throw TraktTransferFailure(status: 503, code: "unavailable", message: "Unavailable") }
        if holdStatus { holdStatus = false; return await withCheckedContinuation { heldStatus = $0 } }
        return connection
    }
    func review(kind: TraktKind, query: String, after: String?) async throws -> TraktSync {
        reads += 1; sequence.append("read")
        if let error = reviewRefusal { reviewRefusal = nil; throw error }
        if holdReview { holdReview = false; return await withCheckedContinuation { heldReview = $0 } }
        if replaceOnRead { var next = snapshot; next.run = nil; return next }
        return snapshot
    }
    func start(mode: TraktRatingMode) async throws -> String { "transfer-run" }
    func step(id: String) async throws -> TraktSync {
        steps += 1
        if let error = stepRefusal { stepRefusal = nil; throw error }
        snapshot.run?.state = "review"
        return snapshot
    }
    func apply(id: String, change: String?, choice: TraktChoice) async throws -> TraktSync {
        applies += 1; sequence.append("write")
        if let error = refusal { refusal = nil; throw error }
        if neverAvailable || failBefore {
            failBefore = false
            throw TraktTransferFailure(status: 429, code: "trakt_rate_limited", message: "Cooldown")
        }
        if (snapshot.counts["safe"] ?? 0) > 0 {
            snapshot.counts["safe", default: 0] -= 1; snapshot.counts["pending", default: 0] -= 1
            snapshot.counts["applied", default: 0] += 1; snapshot.run?.state = "applying"
        } else { snapshot.run?.state = "complete" }
        if loseReceipt { loseReceipt = false; throw TraktTransferFailure(status: 502, code: "unconfirmed_response", message: "Lost response") }
        if hold { hold = false; return await withCheckedContinuation { held = $0 } }
        return snapshot
    }
    func cancel(id: String) async throws { snapshot.run?.state = "cancelled" }
    func disconnect() async throws { snapshot.run = nil }
}
@MainActor final class TraktTransferTests: XCTestCase {
    func testTwoThousandChangesFinishWithoutTheOldHundredRequestStop() async {
        let service = TransferService(total: 2000), clock = TransferClock()
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(service.applies, 2001)
        XCTAssertEqual(controller.sync?.run?.state, "complete")
        XCTAssertEqual(controller.sync?.counts["applied"], 2000)
        XCTAssertNil(controller.error); XCTAssertFalse(controller.paused); XCTAssertFalse(controller.busy)
        XCTAssertEqual(TraktApplyProgress(controller.sync!).percent, 100)
    }
    func testCooldownAutomaticallyReconcilesBeforeContinuing() async {
        let service = TransferService(total: 3), clock = TransferClock(); service.failBefore = true
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(controller.sync?.counts["applied"], 3)
        XCTAssertEqual(Array(service.sequence.prefix(4)), ["read", "write", "read", "write"])
        XCTAssertGreaterThanOrEqual(clock.waits.reduce(0, +), 2)
        XCTAssertNil(controller.error)
    }
    func testLostApplyReceiptIsReadBackAndNeverCreatesAnExtraChange() async {
        let service = TransferService(total: 4), clock = TransferClock(); service.loseReceipt = true
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(service.applies, 5); XCTAssertEqual(controller.sync?.counts["applied"], 4)
        XCTAssertEqual(Array(service.sequence.prefix(4)), ["read", "write", "read", "write"])
        XCTAssertNil(controller.error)
    }
    func testAReplacedReviewCannotInheritThePreviousApplyApproval() async {
        let service = TransferService(total: 4), clock = TransferClock(); service.failBefore = true; service.replaceOnRead = true
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        service.replaceOnRead = false; await controller.refresh(); service.replaceOnRead = true
        await controller.apply()
        XCTAssertEqual(service.applies, 1); XCTAssertNotNil(controller.error); XCTAssertNil(controller.approvedRunID)
    }
    func testUserPauseStopsAfterTheReceiptAndResumeContinuesTheSameRun() async {
        let service = TransferService(total: 5), clock = TransferClock()
        var controller: TraktController!
        controller = TraktController(service: service, clock: { clock.now }, sleep: { value in
            await clock.sleep(value)
            if service.applies == 2 { controller.pauseApplying() }
        })
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(service.applies, 2); XCTAssertTrue(controller.paused); XCTAssertNil(controller.approvedRunID)
        await controller.apply()
        XCTAssertEqual(controller.sync?.counts["applied"], 5); XCTAssertEqual(controller.sync?.run?.state, "complete")
    }
    func testPersistentFailureIsBoundedAndLeavesAnExplicitResumeState() async {
        let service = TransferService(total: 4), clock = TransferClock(); service.neverAvailable = true
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(service.applies, 7); XCTAssertTrue(controller.paused); XCTAssertFalse(controller.busy)
        XCTAssertNotNil(controller.error); XCTAssertEqual(controller.sync?.counts["applied"], 0)
    }
    func testSessionInvalidationRejectsALateReceiptAndPreventsFurtherWrites() async {
        let service = TransferService(total: 4), clock = TransferClock(); service.hold = true
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh()
        let task = Task { await controller.apply() }
        guard await waitForRegressionCondition({ service.held != nil }) else { task.cancel(); XCTFail("No held receipt"); return }
        controller.invalidateSession(); service.held?.resume(returning: service.snapshot); await task.value
        XCTAssertEqual(service.applies, 1); XCTAssertNil(controller.sync); XCTAssertNil(controller.approvedRunID)
    }
    func testOnlyTheSameApprovedRunCanResumeAfterRecreatingTheController() async {
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "different-run"
        let service = TransferService(total: 2), clock = TransferClock()
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.resumeApprovedApply(); XCTAssertEqual(service.applies, 0)
        checkpoint.runID = "transfer-run"; await controller.resumeApprovedApply()
        let finished = await waitForRegressionCondition { controller.sync?.run?.state == "complete" && !controller.busy }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.sync?.counts["applied"], 2); XCTAssertNil(checkpoint.runID)
    }
    func testProgressUsesGlobalCountsAndKeepsFailuresOutOfTheCompletedPercentage() {
        let service = TransferService(total: 2000)
        service.snapshot.counts = ["applied": 200, "skipped": 10, "pending": 1785, "failed": 4, "uncertain": 1, "links": 30, "safe": 1700]
        let progress = TraktApplyProgress(service.snapshot)
        XCTAssertEqual(progress.total, 2000); XCTAssertEqual(progress.finished, 210)
        XCTAssertEqual(progress.remaining, 1790); XCTAssertEqual(progress.failed, 5); XCTAssertEqual(progress.percent, 10)
    }
    func testRetryPolicyHonorsDatesAndDoesNotRetryAccountOrSnapshotConflicts() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TraktTransferFailure.retryDate("60", now: date), date.addingTimeInterval(60))
        XCTAssertEqual(TraktTransferFailure.retryDate("Thu, 01 Jan 1970 00:01:00 GMT", now: date), date.addingTimeInterval(60))
        XCTAssertNil(TraktTransferFailure.retryDate("nonsense", now: date))
        for code in ["trakt_reconnect_required", "trakt_access_limited", "setup_required", "sync_snapshot_changed"] {
            XCTAssertFalse(TraktTransferFailure(status: 503, code: code, message: "Stopped").retryable)
        }
        XCTAssertTrue(TraktTransferFailure(status: 409, code: "sync_busy", message: "Wait").retryable)
    }
    func testProviderRetryAfterIsFullyRespectedBeforeReadBackAndNextWrite() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let start = clock.now
        service.refusal = TraktTransferFailure(status: 429, code: "trakt_rate_limited", message: "Wait", retryAt: start.addingTimeInterval(120))
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(controller.sync?.counts["applied"], 2)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), 120)
        XCTAssertEqual(Array(service.sequence.prefix(4)), ["read", "write", "read", "write"])
        XCTAssertNil(controller.error)
    }
    func testDailyDatabaseQuotaWaitsUntilTheResetBeforeResuming() async {
        let service = TransferService(total: 1), clock = TransferClock()
        let start = clock.now
        service.refusal = APIError.databaseLimit(start.addingTimeInterval(3600))
        let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.apply()
        XCTAssertEqual(controller.sync?.counts["applied"], 1)
        XCTAssertGreaterThanOrEqual(clock.now.timeIntervalSince(start), 3600)
        XCTAssertEqual(Array(service.sequence.prefix(4)), ["read", "write", "read", "write"])
        XCTAssertNil(controller.error)
    }
    func testBackgroundSuspensionRetainsApprovalAndForegroundResumesAfterReadBack() async {
        let service = TransferService(total: 3), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); service.hold = true
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); controller.startApprovedApply()
        guard await waitForRegressionCondition({ service.held != nil }) else { XCTFail("No held request"); return }
        controller.suspendForBackground()
        service.held?.resume(returning: service.snapshot)
        await controller.finishSuspendingTransfer()
        XCTAssertFalse(controller.busy); XCTAssertEqual(service.applies, 1)
        XCTAssertEqual(checkpoint.runID, "transfer-run")
        await controller.refresh(); await controller.resumeApprovedApply()
        let finished = await waitForRegressionCondition { controller.sync?.run?.state == "complete" && !controller.busy }
        XCTAssertTrue(finished); XCTAssertEqual(controller.sync?.counts["applied"], 3)
        XCTAssertNil(checkpoint.runID)
    }
    func testColdQuotaLaunchWaitsForResetAndRestoresApprovedReviewBeforeWriting() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        let reset = clock.now.addingTimeInterval(3600)
        service.statusRefusal = APIError.databaseLimit(reset)
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { interval in
            if clock.now < reset {
                XCTAssertEqual(service.statusReads, 1, "No bootstrap GET before quota reset")
                XCTAssertEqual(service.applies, 0, "No write before account/review restoration")
            }
            await clock.sleep(interval)
        })
        await controller.refresh()
        XCTAssertNil(controller.status); XCTAssertNil(controller.sync)
        await controller.resumeApprovedApply()
        let finished = await waitForRegressionCondition { controller.sync?.run?.state == "complete" && !controller.busy && !controller.loading && service.statusReads == 3 }
        XCTAssertTrue(finished); XCTAssertGreaterThanOrEqual(clock.now, reset)
        XCTAssertEqual(controller.sync?.counts["applied"], 2); XCTAssertNil(checkpoint.runID)
        XCTAssertEqual(service.statusReads, 3) // refusal, bootstrap and final refresh
        XCTAssertEqual(Array(service.sequence.prefix(2)), ["read", "write"])
        XCTAssertNil(controller.error); XCTAssertFalse(controller.restoringApproval)
    }
    func testPauseDuringColdQuotaRecoveryRemovesApprovalWithoutAnyWrite() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        service.statusRefusal = APIError.databaseLimit(clock.now.addingTimeInterval(3600))
        var controller: TraktController!
        controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { interval in
            controller.pauseApplying(); await clock.sleep(interval)
        })
        await controller.refresh(); await controller.resumeApprovedApply()
        let stopped = await waitForRegressionCondition { controller.paused && !controller.busy }
        XCTAssertTrue(stopped); XCTAssertEqual(service.statusReads, 1)
        XCTAssertEqual(service.applies, 0); XCTAssertNil(checkpoint.runID)
        XCTAssertFalse(controller.restoringApproval)
    }
    func testColdReviewReadFailureHonorsRetryAfterAndChecksConnectionAgain() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        let reset = clock.now.addingTimeInterval(120)
        service.reviewRefusal = TraktTransferFailure(status: 429, code: "trakt_rate_limited", message: "Cooldown", retryAt: reset)
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { interval in
            if clock.now < reset { XCTAssertEqual(service.statusReads, 1); XCTAssertEqual(service.reads, 1); XCTAssertEqual(service.applies, 0) }
            await clock.sleep(interval)
        })
        await controller.refresh(); await controller.resumeApprovedApply()
        let finished = await waitForRegressionCondition { controller.sync?.run?.state == "complete" && !controller.busy }
        XCTAssertTrue(finished); XCTAssertGreaterThanOrEqual(clock.now, reset)
        XCTAssertEqual(controller.sync?.counts["applied"], 2); XCTAssertNil(checkpoint.runID)
        XCTAssertEqual(Array(service.sequence.prefix(3)), ["read", "read", "write"])
        XCTAssertNil(controller.error)
    }
    func testColdRecoveryCannotApplyADifferentReviewOrDisconnectedAccount() async {
        for disconnected in [false, true] {
            let service = TransferService(total: 2), clock = TransferClock()
            let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
            service.statusRefusal = TraktTransferFailure(status: 503, code: "unavailable", message: "Unavailable")
            service.replaceOnRead = !disconnected
            service.connection = TraktStatus(configured: true, connected: !disconnected)
            let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
            await controller.refresh(); await controller.resumeApprovedApply()
            let stopped = await waitForRegressionCondition { controller.paused && !controller.busy }
            XCTAssertTrue(stopped); XCTAssertEqual(service.applies, 0); XCTAssertNil(checkpoint.runID)
            XCTAssertNotNil(controller.error)
        }
    }
    func testColdRecoveryInvalidationDiscardsTheLateConnectionBeforeReviewOrWrite() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        service.holdStatus = true
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.resumeApprovedApply()
        guard await waitForRegressionCondition({ service.heldStatus != nil }) else { XCTFail("No held connection"); return }
        controller.invalidateSession(); service.heldStatus?.resume(returning: service.connection)
        let stopped = await waitForRegressionCondition { !controller.busy && !controller.restoringApproval }
        XCTAssertTrue(stopped); XCTAssertEqual(service.reads, 0); XCTAssertEqual(service.applies, 0)
        XCTAssertNil(controller.status); XCTAssertNil(controller.sync); XCTAssertNil(checkpoint.runID)
    }
    func testColdRecoveryIsBoundedWhenStatusKeepsFailing() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        service.statusUnavailable = true
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.resumeApprovedApply()
        let stopped = await waitForRegressionCondition { controller.paused && !controller.busy }
        XCTAssertTrue(stopped); XCTAssertEqual(service.statusReads, 7)
        XCTAssertEqual(service.reads, 0); XCTAssertEqual(service.applies, 0)
        XCTAssertNil(checkpoint.runID); XCTAssertNotNil(controller.error)
    }
    func testBackgroundDuringColdRecoveryPreservesApprovalAndForegroundReadsAgain() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        service.holdStatus = true
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.resumeApprovedApply()
        guard await waitForRegressionCondition({ service.heldStatus != nil }) else { XCTFail("No held connection"); return }
        controller.suspendForBackground(); service.heldStatus?.resume(returning: service.connection)
        await controller.finishSuspendingTransfer()
        XCTAssertEqual(service.applies, 0); XCTAssertEqual(service.reads, 0)
        XCTAssertEqual(checkpoint.runID, "transfer-run"); XCTAssertFalse(controller.busy)
        await controller.refresh(); await controller.resumeApprovedApply()
        let finished = await waitForRegressionCondition { controller.sync?.run?.state == "complete" && !controller.busy }
        XCTAssertTrue(finished); XCTAssertEqual(controller.sync?.counts["applied"], 2); XCTAssertNil(checkpoint.runID)
    }
    func testColdRecoveryNeverRetriesAnExpiredPrivateSession() async {
        let service = TransferService(total: 2), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        service.statusRefusal = APIError.signIn
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.resumeApprovedApply()
        let stopped = await waitForRegressionCondition { controller.paused && !controller.busy }
        XCTAssertTrue(stopped); XCTAssertEqual(service.statusReads, 1)
        XCTAssertEqual(service.applies, 0); XCTAssertTrue(clock.waits.isEmpty); XCTAssertNil(checkpoint.runID)
    }
    func testPauseDuringHeldReadBackCannotBeginAnotherApplyRequest() async {
        let service = TransferService(total: 3), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint()
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); service.failBefore = true; service.holdReview = true
        controller.startApprovedApply()
        guard await waitForRegressionCondition({ service.heldReview != nil }) else { XCTFail("No held read-back"); return }
        XCTAssertEqual(service.applies, 1)
        controller.pauseApplying(); service.heldReview?.resume(returning: service.snapshot)
        let stopped = await waitForRegressionCondition { !controller.busy && !controller.loading }
        XCTAssertTrue(stopped); XCTAssertEqual(service.applies, 1, "Pause must not begin another write after the read")
        XCTAssertNil(checkpoint.runID); XCTAssertEqual(controller.sync?.counts["applied"], 0)
    }
    func testBackgroundDuringHeldReadBackCannotWriteUntilForegroundReadBack() async {
        let service = TransferService(total: 3), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint()
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); service.failBefore = true; service.holdReview = true
        controller.startApprovedApply()
        guard await waitForRegressionCondition({ service.heldReview != nil }) else { XCTFail("No held read-back"); return }
        controller.suspendForBackground(); service.heldReview?.resume(returning: service.snapshot)
        await controller.finishSuspendingTransfer()
        XCTAssertEqual(service.applies, 1); XCTAssertEqual(checkpoint.runID, "transfer-run")
        await controller.refresh(); await controller.resumeApprovedApply()
        let finished = await waitForRegressionCondition { controller.sync?.run?.state == "complete" && !controller.busy }
        XCTAssertTrue(finished); XCTAssertEqual(controller.sync?.counts["applied"], 3); XCTAssertNil(checkpoint.runID)
    }
    func testPausedOrCancelledScanReadBackCannotBeginAnotherStep() async {
        for cancelled in [false, true] {
            let service = TransferService(total: 3), clock = TransferClock()
            service.snapshot.run?.state = "building"
            let controller = TraktController(service: service, clock: { clock.now }, sleep: { await clock.sleep($0) })
            await controller.refresh()
            service.holdReview = true
            service.stepRefusal = TraktTransferFailure(status: 429, code: "trakt_rate_limited", message: "Cooldown")
            let task = Task { await controller.scan(start: false) }
            guard await waitForRegressionCondition({ service.heldReview != nil }) else { task.cancel(); XCTFail("No held scan read-back"); return }
            if cancelled { task.cancel() } else { controller.pauseApplying() }
            service.heldReview?.resume(returning: service.snapshot); await task.value
            XCTAssertEqual(service.steps, 1); XCTAssertTrue(controller.paused); XCTAssertFalse(controller.busy)
            XCTAssertEqual(service.applies, 0)
        }
    }
    func testColdRecoveryAcceptsAnAlreadyCompleteRunWithoutReplayingItsFinalWrite() async {
        let service = TransferService(total: 0), clock = TransferClock()
        let checkpoint = MemoryTraktApplyCheckpoint(); checkpoint.runID = "transfer-run"
        service.snapshot.run?.state = "complete"
        service.statusRefusal = TraktTransferFailure(status: 503, code: "unavailable", message: "Unavailable")
        let controller = TraktController(service: service, checkpoint: checkpoint, clock: { clock.now }, sleep: { await clock.sleep($0) })
        await controller.refresh(); await controller.resumeApprovedApply()
        let finished = await waitForRegressionCondition { controller.sync?.run?.state == "complete" && !controller.busy }
        XCTAssertTrue(finished); XCTAssertTrue(controller.status?.connected == true)
        XCTAssertEqual(service.applies, 0); XCTAssertNil(checkpoint.runID); XCTAssertNil(controller.error)
        XCTAssertFalse(controller.restoringApproval)
    }
}
