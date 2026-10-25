import XCTest
import CryptoKit
import TwilDiaryCore
import TwilDiaryTestSupport
@testable import TwilDiary

@MainActor final class WorkspaceScaleTests: XCTestCase {
    func testLargeProtectedSnapshotsRoundTripAndRecordCacheAndIndexCosts() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProtectedWorkspaceCache(directory: directory, key: SymmetricKey(size: .bits256))
        let savedAt = try XCTUnwrap(DiaryDate.parse("2026-10-23T12:00:00Z"))
        var workspace = SampleWorkspace.make()
        let template = try XCTUnwrap(workspace.events.first)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        let store = DiaryStore(cache: MemoryWorkspaceCache())
        for count in [1_000, 10_000] {
            let rows: [[String: Any]] = (0..<count).map { index in
                var value = row
                value["id"] = "scale-watch-\(index)"
                value["operationId"] = "scale-operation-\(index)"
                return value
            }
            workspace.events = try JSONDecoder().decode([WatchEvent].self, from: JSONSerialization.data(withJSONObject: rows))
            let saveStart = Date.timeIntervalSinceReferenceDate
            try cache.save(workspace, scope: "synthetic-scale-owner", at: savedAt)
            let saveMS = (Date.timeIntervalSinceReferenceDate - saveStart) * 1_000
            let asyncStart = Date.timeIntervalSinceReferenceDate
            try await cache.saveAsynchronously(workspace, scope: "synthetic-scale-owner", at: savedAt)
            let asyncMS = (Date.timeIntervalSinceReferenceDate - asyncStart) * 1_000
            let loadStart = Date.timeIntervalSinceReferenceDate
            let restored = try XCTUnwrap(cache.load(scope: "synthetic-scale-owner"))
            let loadMS = (Date.timeIntervalSinceReferenceDate - loadStart) * 1_000
            let asyncLoadStart = Date.timeIntervalSinceReferenceDate
            let asyncValue = try await cache.loadAsynchronously(scope: "synthetic-scale-owner")
            let asyncRestored = try XCTUnwrap(asyncValue)
            let asyncLoadMS = (Date.timeIntervalSinceReferenceDate - asyncLoadStart) * 1_000
            XCTAssertEqual(asyncRestored.workspace.events, workspace.events)
            XCTAssertEqual(restored.workspace.events, workspace.events)
            XCTAssertEqual(restored.savedAt, savedAt)
            let indexStart = Date.timeIntervalSinceReferenceDate
            store.workspace = restored.workspace
            let indexMS = (Date.timeIntervalSinceReferenceDate - indexStart) * 1_000
            XCTAssertEqual(store.workspace.events.count, count)
            XCTAssertEqual(store.title(template.titleId)?.id, template.titleId)
            XCTAssertNil(cache.load(scope: "a-different-owner"))
            print(String(format: "Workspace scale diagnostic: %d events; synchronous save %.2f ms, asynchronous save total %.2f ms, synchronous load %.2f ms, asynchronous load total %.2f ms, index %.2f ms. Total asynchronous latency is not main-thread blocking time. Simulator diagnostic only, no device timing guarantee.", count, saveMS, asyncMS, loadMS, asyncLoadMS, indexMS))
        }
    }
}
