import XCTest
import CryptoKit
import TwilDiaryCore
import TwilDiaryTestSupport
@testable import TwilDiary

/// A bounded synchronous gate entered only by the detached cache preparer.
final class CachePreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var mainThread = false
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var startedOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func holdFirst() throws {
        lock.lock()
        let first = !entered
        if first { entered = true; mainThread = Thread.isMainThread }
        lock.unlock()
        if first, release.wait(timeout: .now() + 5) != .success {
            throw APIError.message("Synthetic cache preparation gate timed out")
        }
    }
    func resume() { release.signal() }
}

@MainActor final class WorkspaceCacheConcurrencyTests: XCTestCase {
    private let scope = "synthetic-cache-owner"

    func testColdReadYieldsTheMainActorAndRetainsTheExistingOwnerScopedFormat() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate(), key = SymmetricKey(size: .bits256), date = Date(timeIntervalSince1970: 5)
        let cache = ProtectedWorkspaceCache(directory: folder, key: key, beforeLoad: { try gate.holdFirst() })
        let original = SampleWorkspace.make()
        try cache.save(original, scope: scope, at: date)
        XCTAssertNil(cache.residentSnapshot(scope: scope), "A protected disk read must not run synchronously at launch")
        let reading = Task { try await cache.loadAsynchronously(scope: scope) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            reading.cancel(); gate.resume(); _ = try? await reading.value; XCTFail("Cold read never started"); return
        }
        XCTAssertFalse(gate.startedOnMainThread, "The held reader must not block UI actor work")
        gate.resume()
        let value = try await reading.value
        let restored = try XCTUnwrap(value)
        XCTAssertEqual(restored.workspace.events, original.events); XCTAssertEqual(restored.savedAt, date)
        let other = try await cache.loadAsynchronously(scope: "different-owner")
        XCTAssertNil(other)
    }

    func testRemovalInvalidatesAnInFlightColdRead() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforeLoad: { try gate.holdFirst() })
        try cache.save(SampleWorkspace.make(), scope: scope, at: .now)
        let reading = Task { try await cache.loadAsynchronously(scope: scope) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            reading.cancel(); gate.resume(); _ = try? await reading.value; XCTFail("Cold read never started"); return
        }
        try cache.removeAll(); gate.resume()
        do { _ = try await reading.value; XCTFail("An invalidated read must never publish") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testNewerSaveInvalidatesAnOlderColdReadAndCancellationKeepsTheFile() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforeLoad: { try gate.holdFirst() })
        try cache.save(SampleWorkspace.make(), scope: scope, at: .distantPast)
        let reading = Task { try await cache.loadAsynchronously(scope: scope) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            reading.cancel(); gate.resume(); _ = try? await reading.value; XCTFail("Cold read never started"); return
        }
        let date = Date(timeIntervalSince1970: 6)
        try await cache.saveAsynchronously(Workspace(), scope: scope, at: date)
        gate.resume()
        do { _ = try await reading.value; XCTFail("An older reader must not publish after a newer save") }
        catch is CancellationError { }
        let cancelled = Task { try await cache.loadAsynchronously(scope: scope) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A cancelled reader was accepted") }
        catch is CancellationError { }
        XCTAssertEqual(cache.load(scope: scope)?.savedAt, date)
        XCTAssertEqual(cache.load(scope: scope)?.workspace.events.count, 0)
    }

    func testDetachedPreparationYieldsTheMainActorAndKeepsTheExistingEncryptedFormat() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate(), key = SymmetricKey(size: .bits256)
        let cache = ProtectedWorkspaceCache(directory: folder, key: key, beforePrepare: { try gate.holdFirst() })
        let value = SampleWorkspace.make(), date = Date(timeIntervalSince1970: 0)
        let saving = Task { try await cache.saveAsynchronously(value, scope: scope, at: date) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            saving.cancel(); gate.resume(); _ = try? await saving.value; XCTFail("Preparation never started"); return
        }
        XCTAssertFalse(gate.startedOnMainThread, "JSON/encryption preparation must execute outside the UI thread")
        XCTAssertNil(cache.load(scope: scope), "No partially prepared file may be published")
        gate.resume(); try await saving.value
        let reader = ProtectedWorkspaceCache(directory: folder, key: key)
        XCTAssertEqual(reader.load(scope: scope)?.workspace.events, value.events)
        XCTAssertEqual(reader.load(scope: scope)?.savedAt, date)
        XCTAssertNil(reader.load(scope: "different-owner"))
    }

    func testSignOutRemovalInvalidatesPreparationBeforeItCanRecreateTheFile() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforePrepare: { try gate.holdFirst() })
        let saving = Task { try await cache.saveAsynchronously(SampleWorkspace.make(), scope: scope, at: .now) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            saving.cancel(); gate.resume(); _ = try? await saving.value; XCTFail("Preparation never started"); return
        }
        try cache.removeAll(); gate.resume()
        do { try await saving.value; XCTFail("Removed generation was committed") }
        catch is CancellationError { }
        XCTAssertNil(cache.load(scope: scope)); XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testNewerSaveWinsWhenAnOlderPreparationFinishesLater() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforePrepare: { try gate.holdFirst() })
        let old = Task { try await cache.saveAsynchronously(SampleWorkspace.make(), scope: scope, at: .distantPast) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            old.cancel(); gate.resume(); _ = try? await old.value; XCTFail("Older preparation never started"); return
        }
        let latest = Date(timeIntervalSince1970: 1)
        try await cache.saveAsynchronously(Workspace(), scope: scope, at: latest)
        gate.resume()
        do { try await old.value; XCTFail("The older preparation overwrote the new snapshot") }
        catch is CancellationError { }
        XCTAssertEqual(cache.load(scope: scope)?.workspace.events.count, 0)
        XCTAssertEqual(cache.load(scope: scope)?.savedAt, latest)
    }

    func testCancelledPreparationPreservesThePreviouslyLoadableSnapshot() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforePrepare: { try gate.holdFirst() })
        let date = Date(timeIntervalSince1970: 2)
        try cache.save(Workspace(), scope: scope, at: date)
        let saving = Task { try await cache.saveAsynchronously(SampleWorkspace.make(), scope: scope, at: .now) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            saving.cancel(); gate.resume(); _ = try? await saving.value; XCTFail("Preparation never started"); return
        }
        saving.cancel(); gate.resume()
        do { try await saving.value; XCTFail("Cancelled preparation was committed") }
        catch is CancellationError { }
        XCTAssertEqual(cache.load(scope: scope)?.workspace.events.count, 0)
        XCTAssertEqual(cache.load(scope: scope)?.savedAt, date)
    }

    func testAsynchronousOversizeFailurePreservesThePreviousEncryptedSnapshot() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256), date = Date(timeIntervalSince1970: 3)
        let original = ProtectedWorkspaceCache(directory: folder, key: key)
        try original.save(Workspace(), scope: scope, at: date)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let previous = try Data(contentsOf: file)
        let bounded = ProtectedWorkspaceCache(directory: folder, key: key, maximumBytes: previous.count)
        do {
            try await bounded.saveAsynchronously(SampleWorkspace.make(), scope: scope, at: date)
            XCTFail("An over-limit preparation must fail")
        } catch is APIError { }
        XCTAssertEqual(try Data(contentsOf: file), previous)
        XCTAssertEqual(bounded.load(scope: scope)?.savedAt, date)
        XCTAssertEqual(bounded.load(scope: scope)?.workspace.events.count, 0)
    }
}
