import XCTest
import CryptoKit
import TwilDiaryCore
import TwilDiaryTestSupport
@testable import TwilDiary

@MainActor final class WorkspaceCacheTests: XCTestCase {
    func testOversizedSnapshotCannotReplaceALoadableCacheAndTheExactLimitLoads() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), scope = "synthetic-owner", date = Date(timeIntervalSince1970: 0)
        let original = ProtectedWorkspaceCache(directory: directory, key: key)
        try original.save(Workspace(), scope: scope, at: date)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let exactLimit = try Data(contentsOf: file).count
        let bounded = ProtectedWorkspaceCache(directory: directory, key: key, maximumBytes: exactLimit)
        try bounded.save(Workspace(), scope: scope, at: date)
        let good = try Data(contentsOf: file)
        XCTAssertEqual(good.count, exactLimit)
        XCTAssertNotNil(bounded.load(scope: scope))
        XCTAssertThrowsError(try bounded.save(SampleWorkspace.make(), scope: scope, at: date))
        XCTAssertEqual(try Data(contentsOf: file), good, "An over-limit write must preserve the previous valid encrypted snapshot")
        XCTAssertEqual(bounded.load(scope: scope)?.workspace.titles.count, 0)
        // Simulate an older writer having saved a larger, correctly sealed file.
        try original.save(SampleWorkspace.make(), scope: scope, at: date)
        XCTAssertNil(bounded.load(scope: scope))
    }
    func testProtectedSnapshotSurvivesRelaunchButNeverCrossesOwners() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), now = Date.now
        let cache = ProtectedWorkspaceCache(directory: directory, key: key)
        let workspace = SampleWorkspace.make()
        try cache.save(workspace, scope: "synthetic-owner", at: now)
        let relaunched = ProtectedWorkspaceCache(directory: directory, key: key)
        let restored = try XCTUnwrap(relaunched.load(scope: "synthetic-owner"))
        XCTAssertEqual(restored.workspace.titles, workspace.titles)
        XCTAssertEqual(restored.savedAt, now)
        XCTAssertNil(relaunched.load(scope: "another-owner"))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertFalse(try Data(contentsOf: file).range(of: Data(workspace.titles[0].name.utf8)) != nil, "Diary plaintext must not be written to disk")
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try cache.removeAll()
        XCTAssertNil(relaunched.load(scope: "synthetic-owner"))
    }
    func testTamperingOrWrongKeyNeverPublishesPartialData() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProtectedWorkspaceCache(directory: directory, key: SymmetricKey(size: .bits256))
        try cache.save(SampleWorkspace.make(), scope: "synthetic-owner", at: .now)
        XCTAssertNil(ProtectedWorkspaceCache(directory: directory, key: SymmetricKey(size: .bits256)).load(scope: "synthetic-owner"))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var bytes = try Data(contentsOf: file); bytes[bytes.count / 2] ^= 1
        try bytes.write(to: file, options: .atomic)
        XCTAssertNil(cache.load(scope: "synthetic-owner"))
    }
    func testTokenRenewalKeepsScopeButAnotherIdentityDoesNot() throws {
        func credential(_ subject: String, signature: String) throws -> AccessCredential {
            let data = try JSONSerialization.data(withJSONObject: ["iss": "https://fixture.test", "sub": subject])
            let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return AccessCredential(token: "fixture.\(payload).\(signature)", expires: .distantFuture)
        }
        XCTAssertEqual(try credential("one", signature: "a").cacheScope, try credential("one", signature: "b").cacheScope)
        XCTAssertNotEqual(try credential("one", signature: "a").cacheScope, try credential("two", signature: "a").cacheScope)
    }
    func testDuplicateSnapshotsCannotReplaceACacheAndLegacyDuplicatesCannotLoad() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256), scope = "synthetic-owner", now = Date.now
        let original = SampleWorkspace.make()
        var malformed = original; malformed.events.append(try XCTUnwrap(original.events.first))
        let cache = ProtectedWorkspaceCache(directory: directory, key: key)
        try cache.save(original, scope: scope, at: now)
        XCTAssertThrowsError(try cache.save(malformed, scope: scope, at: now))
        XCTAssertEqual(cache.load(scope: scope)?.workspace.events, original.events)
        let memory = MemoryWorkspaceCache()
        try memory.save(original, scope: scope, at: now)
        XCTAssertThrowsError(try memory.save(malformed, scope: scope, at: now))
        XCTAssertEqual(memory.load(scope: scope)?.workspace.events, original.events)
        // Simulate an older client having persisted a malformed but correctly encrypted snapshot.
        let snapshot = CachedWorkspace(schema: 1, scope: scope, savedAt: now, workspace: malformed)
        let plaintext = try JSONEncoder().encode(snapshot)
        let encrypted = try XCTUnwrap(AES.GCM.seal(plaintext, using: key, authenticating: Data(scope.utf8)).combined)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try encrypted.write(to: file, options: .atomic)
        XCTAssertNil(cache.load(scope: scope))
    }
}
