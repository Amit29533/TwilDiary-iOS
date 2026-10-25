import XCTest
@testable import TwilDiary

@MainActor private final class IncomingFixture: IncomingTraktServicing {
    var value = IncomingTraktStatus(enabled: false, pending: 0, review: 0)
    var rejected = false
    var choices: [Bool] = []
    var gate: CheckedContinuation<Void, Never>?
    var hold = false
    func status() async throws -> IncomingTraktStatus {
        if rejected { throw APIError.message("Synthetic outage") }
        return value
    }
    func configure(enabled: Bool) async throws -> IncomingTraktStatus {
        choices.append(enabled)
        if hold { await withCheckedContinuation { gate = $0 } }
        if rejected { throw APIError.message("Synthetic outage") }
        value.enabled = enabled; return value
    }
}

@MainActor final class IncomingTraktTests: XCTestCase {
    func testOlderBackendHealthDecodesWithoutNewOptionalFields() throws {
        let value = try JSONDecoder().decode(IncomingTraktStatus.self, from: Data(#"{"enabled":true,"pending":0,"review":0,"paused":false}"#.utf8))
        XCTAssertNil(value.pausedBy); XCTAssertNil(value.overdue)
    }
    func testOverdueHealthTakesPriorityOverStoredProviderError() async {
        let service = IncomingFixture(); service.value.enabled = true
        service.value.overdue = true; service.value.error = "trakt_rate_limited"
        let controller = IncomingTraktController(service: service); await controller.refresh()
        XCTAssertTrue(controller.health?.contains("10 minutes") ?? false)
        service.value.overdue = false; await controller.refresh()
        XCTAssertTrue(controller.health?.contains("cooldown") ?? false)
    }
    func testPauseExplainsTheBlockingPhaseAndSevenDayCatchupWindow() async {
        let service = IncomingFixture(); service.value.paused = true; service.value.pausedBy = "building"
        let controller = IncomingTraktController(service: service); await controller.refresh()
        XCTAssertTrue(controller.pauseExplanation?.contains("scan is running") ?? false)
        for phase in ["review", "applying"] {
            service.value.pausedBy = phase; await controller.refresh()
            XCTAssertTrue(controller.pauseExplanation?.contains("finish or cancel") ?? false)
            XCTAssertTrue(controller.pauseExplanation?.contains("seven days") ?? false)
        }
        service.value.paused = false; await controller.refresh(); XCTAssertNil(controller.pauseExplanation)
    }
    func testServerAcknowledgementControlsTheSettingAndRefreshPreservesIt() async {
        let service = IncomingFixture()
        let current = IncomingTraktController(service: service)
        await current.refresh(); XCTAssertFalse(current.status?.enabled ?? true)
        await current.configure(enabled: true); XCTAssertTrue(current.status?.enabled ?? false)
        await current.refresh(); XCTAssertTrue(current.status?.enabled ?? false)
        await current.configure(enabled: false); XCTAssertFalse(current.status?.enabled ?? true)
        XCTAssertEqual(service.choices, [true, false]); XCTAssertNil(current.error)
    }
    func testLostResponseKeepsLastConfirmedSettingAndOffersStatusRecovery() async {
        let service = IncomingFixture()
        let controller = IncomingTraktController(service: service)
        await controller.refresh(); service.rejected = true
        await controller.configure(enabled: true)
        XCTAssertFalse(controller.status?.enabled ?? true); XCTAssertNotNil(controller.error)
        service.rejected = false; service.value.enabled = true
        await controller.refresh(); XCTAssertTrue(controller.status?.enabled ?? false); XCTAssertNil(controller.error)
    }
    func testRapidToggleAndStatusRefreshCannotOverlapASettingWrite() async {
        let service = IncomingFixture()
        let current = IncomingTraktController(service: service)
        await current.refresh(); service.hold = true
        let task = Task { await current.configure(enabled: true) }
        guard await waitForRegressionCondition({ service.gate != nil }) else {
            task.cancel(); service.gate?.resume(); await task.value; XCTFail("Setting write did not reach the fixture"); return
        }
        XCTAssertTrue(current.busy); XCTAssertFalse(current.status?.enabled ?? true)
        await current.configure(enabled: false); await current.refresh()
        XCTAssertEqual(service.choices, [true])
        service.gate?.resume(); await task.value
        XCTAssertTrue(current.status?.enabled ?? false); XCTAssertFalse(current.busy)
    }
    func testUnavailableBackendDoesNotEnableTheFeatureOrInventAHealthTimestamp() async {
        let service = IncomingFixture(); service.rejected = true
        let controller = IncomingTraktController(service: service)
        await controller.refresh()
        XCTAssertNil(controller.status); XCTAssertNotNil(controller.error); XCTAssertFalse(controller.busy)
    }
    func testProviderCooldownAndDailyLimitHaveActionableHealthCopy() async {
        let service = IncomingFixture()
        let current = IncomingTraktController(service: service)
        service.value.error = "trakt_rate_limited"; await current.refresh()
        XCTAssertTrue(current.health?.contains("cooldown") ?? false)
        service.value.error = "incoming_daily_budget"; await current.refresh()
        XCTAssertTrue(current.health?.contains("midnight UTC") ?? false)
        service.value.error = nil; await current.refresh(); XCTAssertNil(current.health)
    }
}
