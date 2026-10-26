import XCTest
import CryptoKit
import TwilDiaryCore
@testable import TwilDiary

@MainActor private final class MemorySessionStorage: SessionStoring {
    var credential: AccessCredential?
    var rejectSave = false
    func read() -> AccessCredential? { credential }
    func save(_ value: AccessCredential) throws {
        if rejectSave { throw APIError.message("Test storage unavailable") }
        credential = value
    }
    func delete() { credential = nil }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    /// URLProtocol callbacks are synchronous. The lock protects held completions across its queues.
    final class ResponseGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completions: [@Sendable () -> Void] = []
        private var released = false
        func submit(_ completion: @escaping @Sendable () -> Void) {
            lock.lock()
            if released { lock.unlock(); completion() }
            else { completions.append(completion); lock.unlock() }
        }
        func release() {
            lock.lock()
            released = true
            let pending = completions; completions.removeAll()
            lock.unlock()
            for completion in pending { completion() }
        }
    }
    struct Reply: Sendable {
        let status: Int
        let contentType: String
        let body: String
        var delay: TimeInterval = 0
        var gate: ResponseGate? = nil
        var failureCode: URLError.Code? = nil
        var headers: [String: String] = [:]
        init(_ body: String) { self.init(200, body) }
        init(_ status: Int, _ body: String, contentType: String = "application/json") {
            self.status = status; self.body = body; self.contentType = contentType
        }
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        private var identifier = UUID().uuidString
        private var handler: @Sendable (URLRequest) -> Reply = { _ in Reply(500, "{}") }
        private var requests: [URLRequest] = []
        var testIdentifier: String { lock.lock(); defer { lock.unlock() }; return identifier }
        func beginTest() {
            lock.lock(); defer { lock.unlock() }
            identifier = UUID().uuidString; requests = []
            handler = { _ in Reply(500, "{}") }
        }
        func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
            lock.lock(); defer { lock.unlock() }
            self.handler = handler; requests = []
        }
        func reply(_ request: URLRequest) -> Reply {
            var recorded = request
            if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
                recorded.httpBody = data
            }
            lock.lock()
            guard recorded.value(forHTTPHeaderField: "X-TwilDiary-Test-Case") == identifier else {
                lock.unlock()
                var stale = Reply("{}"); stale.failureCode = .cancelled; return stale
            }
            requests.append(recorded); let handler = handler; lock.unlock()
            return handler(recorded)
        }
        func recorded() -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }; return requests
        }
    }
    static let state = State()
    private let deliveryLock = NSRecursiveLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.reply(request)
        if let gate = reply.gate {
            gate.submit { self.deliver(reply) }
        } else if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { self.deliver(reply) }
        } else { deliver(reply) }
    }
    private func deliver(_ reply: Reply) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        guard !stopped else { return }
        if let code = reply.failureCode { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": reply.contentType].merging(reply.headers, uniquingKeysWith: { _, new in new }))!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !stopped else { return }
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        guard !stopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { deliveryLock.lock(); stopped = true; deliveryLock.unlock() }
}

private final class WorkspaceDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func pause() -> Bool {
        lock.lock(); started = true; lock.unlock()
        return release.wait(timeout: .now() + 3) == .success
    }
    func resume() { release.signal() }
}
private final class WorkspaceDecodeState: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: WorkspaceDecodeGate?
    func set(_ value: WorkspaceDecodeGate?) { lock.lock(); gate = value; lock.unlock() }
    func get() -> WorkspaceDecodeGate? { lock.lock(); defer { lock.unlock() }; return gate }
}
private struct WorkspaceDecodeProbe: Decodable, Sendable {
    static let state = WorkspaceDecodeState()
    let value: Int
    let decodedOnMainThread: Bool
    enum CodingKeys: String, CodingKey { case value }
    init(from decoder: Decoder) throws {
        value = try decoder.container(keyedBy: CodingKeys.self).decode(Int.self, forKey: .value)
        decodedOnMainThread = Thread.isMainThread
        if let gate = Self.state.get(), !gate.pause() { throw APIError.message("Synthetic decoder gate timed out") }
    }
}

@MainActor final class SessionTests: XCTestCase {
    private let credential = AccessCredential(token: "synthetic-test-session", expires: .distantFuture)
    nonisolated override func setUpWithError() throws { StubProtocol.state.beginTest() }
    private func api(_ storage: MemorySessionStorage, clock: @escaping @MainActor () -> Date = { .now }) -> DiaryAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-TwilDiary-Test-Case": StubProtocol.state.testIdentifier]
        return DiaryAPI(configuration: configuration, storage: storage, clock: clock)
    }
    func testStubSessionsCannotConsumeAnotherTestsHandlerOrRequestCount() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let old = api(storage)
        StubProtocol.state.beginTest()
        StubProtocol.state.reset { _ in .init("{}") }
        do { let _: EmptyResponse = try await old.request("/api/glance/stale-test"); XCTFail("Old test session was accepted") }
        catch is CancellationError { }
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty)
        let _: EmptyResponse = try await api(storage).request("/api/glance/current-test")
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }
    func testT29DroppedGETRetriesOnceAndPOSTDoesNotRetry() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        for method in ["GET", "POST"] {
            StubProtocol.state.reset { _ in
                if StubProtocol.state.recorded().count == 1 { var reply = StubProtocol.Reply("{}"); reply.failureCode = .networkConnectionLost; return reply }
                return .init("{}")
            }
            do {
                let _: EmptyResponse = try await api(storage).request("/api/glance/again", method: method)
                XCTAssertEqual(method, "GET")
            } catch {
                XCTAssertEqual(method, "POST"); XCTAssertTrue(error.localizedDescription.contains("connection dropped"))
                XCTAssertTrue(error.localizedDescription.contains("not confirmed"), "A lost POST response must never promise that the server stayed unchanged")
            }
            XCTAssertEqual(StubProtocol.state.recorded().count, method == "GET" ? 2 : 1)
        }
    }
    func testT29OfflineTimeoutAndCancellationDoNotRetryOrSignOut() async {
        for code in [URLError.notConnectedToInternet, .timedOut, .cancelled] {
            StubProtocol.state.reset { _ in var reply = StubProtocol.Reply("{}"); reply.failureCode = code; return reply }
            let storage = MemorySessionStorage(); storage.credential = credential
            let store = DiaryStore(api: api(storage))
            do {
                let _: EmptyResponse = try await store.read("/api/glance/again")
                XCTFail("Expected transport failure")
            } catch is CancellationError { XCTAssertEqual(code, .cancelled) }
            catch { XCTAssertFalse(error.localizedDescription.contains("NSURLErrorDomain")) }
            XCTAssertFalse(store.needsSignIn); XCTAssertEqual(StubProtocol.state.recorded().count, 1)
        }
    }
    func testT27QuotaStopsFurtherReadsAndForegroundButExplicitRefreshCanRecover() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        let start = Date(timeIntervalSince1970: 1_792_886_400)
        let network = api(storage, clock: { start })
        // Use the same transport instance for the store and its quota state.
        let blockedStore = DiaryStore(api: network)
        StubProtocol.state.reset { _ in .init(503, #"{"error":{"code":"database_read_limit","message":"Quota","resetAt":"2999-01-01T00:00:00Z"}}"#) }
        let _: EmptyResponse? = try? await blockedStore.read("/api/glance/again")
        XCTAssertNotNil(blockedStore.quotaBlockedUntil)
        let before = StubProtocol.state.recorded().count
        let _: EmptyResponse? = try? await blockedStore.read("/api/glance/other")
        await blockedStore.refreshOnForeground(at: start)
        XCTAssertEqual(StubProtocol.state.recorded().count, before)
        StubProtocol.state.reset { _ in .init(#"{"items":[],"next":null}"#) }
        await blockedStore.refresh()
        XCTAssertEqual(StubProtocol.state.recorded().count, 4)
        XCTAssertNil(blockedStore.quotaBlockedUntil); XCTAssertTrue(blockedStore.hasLoadedWorkspace)
        XCTAssertFalse(blockedStore.needsSignIn)
    }
    func testT27QuotaExpiresByTheInjectedClockAndMissingResetUsesUTCMidnight() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        var time = try XCTUnwrap(DiaryDate.parse("2026-10-25T23:30:00Z"))
        let network = api(storage, clock: { time })
        StubProtocol.state.reset { _ in .init(503, #"{"error":{"code":"database_write_limit","message":"Quota"}}"#) }
        let _: EmptyResponse? = try? await network.request("/api/glance/again")
        XCTAssertEqual(network.quotaBlockedUntil, DiaryDate.parse("2026-10-26T00:00:00Z"))
        time = try XCTUnwrap(DiaryDate.parse("2026-10-26T00:00:01Z"))
        StubProtocol.state.reset { _ in .init("{}") }
        let _: EmptyResponse = try await network.request("/api/glance/again")
        XCTAssertEqual(StubProtocol.state.recorded().count, 1); XCTAssertNil(network.quotaBlockedUntil)
    }
    func testT27AnOlderSuccessfulReadCannotEraseANewerQuotaOrAnExplicitRetry() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let network = api(storage), gate = StubProtocol.ResponseGate()
        StubProtocol.state.reset { request in
            if request.url?.path == "/api/glance/slow" { var reply = StubProtocol.Reply("{}"); reply.gate = gate; return reply }
            return .init(503, #"{"error":{"code":"database_read_limit","message":"Quota","resetAt":"2999-01-01T00:00:00Z"}}"#)
        }
        let old = Task { let _: EmptyResponse = try await network.request("/api/glance/slow") }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().count == 1 }) else {
            old.cancel(); gate.release(); _ = try? await old.value; XCTFail("Held read never started"); return
        }
        let _: EmptyResponse? = try? await network.request("/api/glance/quota")
        XCTAssertTrue(network.isQuotaBlocked)
        gate.release(); _ = try await old.value
        XCTAssertTrue(network.isQuotaBlocked, "The older success must not clear the newer circuit breaker")
        network.retryQuota(); XCTAssertFalse(network.isQuotaBlocked)
    }

    func testWorkspacePagesDecodeOutsideTheMainThread() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        WorkspaceDecodeProbe.state.set(nil)
        StubProtocol.state.reset { _ in .init(#"{"items":[{"value":1}],"next":null}"#) }
        let values = try await api(storage).allPages("titles", as: WorkspaceDecodeProbe.self)
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values.first?.value, 1)
        XCTAssertEqual(values.first?.decodedOnMainThread, false)
    }
    func testSignOutDuringBackgroundDecodeRejectsTheOldPage() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        let network = api(storage), gate = WorkspaceDecodeGate()
        WorkspaceDecodeProbe.state.set(gate); defer { gate.resume(); WorkspaceDecodeProbe.state.set(nil) }
        StubProtocol.state.reset { _ in .init(#"{"items":[{"value":1}],"next":null}"#) }
        let pending = Task { try await network.allPages("titles", as: WorkspaceDecodeProbe.self) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            pending.cancel(); gate.resume(); _ = try? await pending.value; XCTFail("Background decode never started"); return
        }
        network.signOut(); gate.resume()
        do { _ = try await pending.value; XCTFail("A decoded old-session page must not return") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation after sign-out") }
    }
    func testCancellingAWorkspaceReadAlsoCancelsItsBackgroundDecode() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        let network = api(storage), gate = WorkspaceDecodeGate()
        WorkspaceDecodeProbe.state.set(gate); defer { gate.resume(); WorkspaceDecodeProbe.state.set(nil) }
        StubProtocol.state.reset { _ in .init(#"{"items":[{"value":1}],"next":null}"#) }
        let pending = Task { try await network.allPages("titles", as: WorkspaceDecodeProbe.self) }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            pending.cancel(); gate.resume(); _ = try? await pending.value; XCTFail("Background decode never started"); return
        }
        pending.cancel(); gate.resume()
        do { _ = try await pending.value; XCTFail("A cancelled decode must not return a page") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation after read cancellation") }
    }

    func testForegroundRefreshReadsTheLatestDiaryAndCoalescesRapidSceneChanges() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init(#"{"items":[],"next":null}"#) }
        let store = DiaryStore(api: api(storage)), start = Date.now
        store.workspace = PreviewData.workspace; store.hasLoadedWorkspace = true
        await store.refreshOnForeground(at: start)
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertEqual(StubProtocol.state.recorded().count, 4)
        await store.refreshOnForeground(at: start.addingTimeInterval(1))
        XCTAssertEqual(StubProtocol.state.recorded().count, 4)
        await store.refreshOnForeground(at: start.addingTimeInterval(11))
        XCTAssertEqual(StubProtocol.state.recorded().count, 8)
    }
    func testForegroundReadWaitsForAnInFlightWriteBeforeLoadingTheServerSnapshot() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init(#"{"items":[],"next":null}"#) }
        let store = DiaryStore(api: api(storage)); store.busy = true
        var started = false
        let pending = Task { started = true; await store.refreshOnForeground() }
        guard await waitForRegressionCondition({ started }) else {
            pending.cancel(); store.busy = false; await pending.value; XCTFail("Foreground task did not start"); return
        }
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty)
        store.busy = false; await pending.value
        XCTAssertEqual(StubProtocol.state.recorded().count, 4)
    }
    func testCancelledForegroundWaitDoesNotConsumeTheNextResumeRefresh() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init(#"{"items":[],"next":null}"#) }
        let store = DiaryStore(api: api(storage)); store.busy = true
        var started = false
        let pending = Task { started = true; await store.refreshOnForeground() }
        guard await waitForRegressionCondition({ started }) else {
            pending.cancel(); store.busy = false; await pending.value; XCTFail("Foreground task did not start"); return
        }
        pending.cancel(); store.busy = false; await pending.value
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty)
        await store.refreshOnForeground()
        XCTAssertEqual(StubProtocol.state.recorded().count, 4)
    }

    func testCatalogSeasonUsesReadOnlyEndpointAndExplicitSpoilerChoice() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init(#"{"items":[{"number":1,"name":"","overview":"","airedOn":null,"stillPath":null,"communityScore":8.1}]}"#) }
        let store = DiaryStore(api: api(storage))
        let result = try await store.catalogEpisodes(CatalogRoute(kind: .tv, id: 900001), season: 2, reveal: false)
        XCTAssertEqual(result.items.first?.name, "")
        _ = try await store.catalogEpisodes(CatalogRoute(kind: .tv, id: 900001), season: 2, reveal: true)
        let requests = StubProtocol.state.recorded()
        XCTAssertEqual(requests.count, 2)
        for request in requests { XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/api/metadata/season") }
        let firstQuery = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(firstQuery?.first { $0.name == "season" }?.value, "2")
        XCTAssertEqual(firstQuery?.first { $0.name == "reveal" }?.value, "0")
        let lastQuery = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(lastQuery?.first { $0.name == "reveal" }?.value, "1")
        do { _ = try await store.catalogEpisodes(CatalogRoute(kind: .movie, id: 900001), season: 1, reveal: false); XCTFail("Movies must not fetch seasons") } catch { }
        XCTAssertEqual(StubProtocol.state.recorded().count, 2)
    }
    func testCatalogImportRefreshFailureKeepsConfirmedIdentityRetrySafe() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { request in
            if request.url?.path == "/api/metadata/import" { return .init(#"{"title":{"id":"tmdb-tv-900001"}}"#) }
            return .init(503, #"{"error":{"message":"Synthetic read outage"}}"#)
        }
        let store = DiaryStore(api: api(storage)), details = PreviewCatalog.browse(CatalogRoute(kind: .tv, id: 900001)).details
        let first = await store.importTitle(details, category: details.suggestedCategory)
        XCTAssertNil(first); XCTAssertFalse(store.busy)
        XCTAssertTrue(store.error?.contains("a second copy will not be created") == true)
        let request = try XCTUnwrap(StubProtocol.state.recorded().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(body["mediaType"] as? String, "tv"); XCTAssertEqual(body["tmdbId"] as? Int, 900001)
        XCTAssertEqual(body["status"] as? String, "planned"); XCTAssertTrue(body["score"] is NSNull)
    }

    func testManualCreateRefreshFailureRetainsCallerIdentityAndExplicitNulls() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { request in
            if request.url?.path == "/api/titles" { return .init(#"{"title":{"id":"manual-reference"}}"#) }
            return .init(503, #"{"error":{"message":"Synthetic read outage"}}"#)
        }
        let store = DiaryStore(api: api(storage)); var draft = ManualTitleDraft(); draft.name = "Reference"
        do { _ = try await store.createManualTitle(draft.validated(id: "manual-reference")); XCTFail("A failed refresh must remain retryable") }
        catch { XCTAssertTrue(error.localizedDescription.contains("a second copy will not be created")) }
        XCTAssertFalse(store.busy)
        let request = try XCTUnwrap(StubProtocol.state.recorded().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, "manual-reference"); XCTAssertTrue(body["score"] is NSNull); XCTAssertTrue(body["year"] is NSNull)
    }

    func testLateCatalogImportCannotPublishAnErrorAfterSignOut() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in var reply = StubProtocol.Reply(#"{"title":{"id":"tmdb-tv-900001"}}"#); reply.delay = 0.15; return reply }
        let store = DiaryStore(api: api(storage)), details = PreviewCatalog.browse(CatalogRoute(kind: .tv, id: 900001)).details
        let task = Task { await store.importTitle(details, category: details.suggestedCategory) }
        guard await waitForRegressionCondition({ !StubProtocol.state.recorded().isEmpty }) else { task.cancel(); XCTFail("The import request did not start"); return }
        store.signOut(); let result = await task.value
        XCTAssertNil(result); XCTAssertNil(store.error); XCTAssertTrue(store.needsSignIn); XCTAssertFalse(store.busy)
        XCTAssertTrue(store.workspace.titles.isEmpty)
    }

    func testSignInSurvivesDatabaseQuotaAndDoesNotProbeWorkspaceForAuthentication() async {
        let titles = StubProtocol.ResponseGate(), siblings = StubProtocol.ResponseGate()
        StubProtocol.state.reset { request in
            if request.url?.path == "/api/session" { return .init(#"{"authenticated":true}"#) }
            var reply = StubProtocol.Reply(503, #"{"error":{"code":"database_read_limit","message":"Quota exhausted","resetAt":"2999-01-01T00:00:00.000Z"}}"#)
            reply.gate = request.url?.query == "section=titles" ? titles : siblings
            return reply
        }
        let storage = MemorySessionStorage(), api = api(storage)
        let store = DiaryStore(api: api)
        let connection = Task { await store.connect(credential) }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().count == 5 }) else {
            connection.cancel(); titles.release(); siblings.release(); await connection.value
            XCTFail("All four workspace reads must start before releasing the quota responses"); return
        }
        // Awaiting the title async-let must still report a quota when another
        // section responded first. Previously its response became cancellation.
        siblings.release()
        guard await waitForRegressionCondition({ api.isQuotaBlocked }) else {
            connection.cancel(); titles.release(); await connection.value
            XCTFail("Sibling quota response did not open the circuit breaker"); return
        }
        titles.release(); await connection.value
        XCTAssertFalse(store.needsSignIn)
        XCTAssertFalse(store.hasLoadedWorkspace)
        XCTAssertFalse(store.loading)
        XCTAssertEqual(storage.credential?.token, credential.token)
        XCTAssertEqual(api.credential?.token, credential.token)
        XCTAssertTrue(store.error?.contains("daily database limit") == true)
        let requests = StubProtocol.state.recorded()
        XCTAssertEqual(requests.first?.url?.path, "/api/session")
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.url?.path == "/api/workspace" })
        XCTAssertEqual(requests.count - 1, 4)
        XCTAssertTrue(requests.contains { $0.url?.query == "section=titles" })
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=synthetic-test-session")
    }

    func testT27ExpiredServerResetStillBlocksUntilTheNextUTCMidnight() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let time = try XCTUnwrap(DiaryDate.parse("2026-10-25T08:00:00Z"))
        let network = api(storage, clock: { time })
        StubProtocol.state.reset { _ in .init(503, #"{"error":{"code":"database_read_limit","message":"Quota","resetAt":"2026-10-24T00:00:00.000Z"}}"#) }
        let _: EmptyResponse? = try? await network.request("/api/glance/quota")
        XCTAssertTrue(network.isQuotaBlocked)
        XCTAssertEqual(network.quotaBlockedUntil, DiaryDate.parse("2026-10-26T00:00:00Z"))
        let _: EmptyResponse? = try? await network.request("/api/glance/again")
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }

    func testT27LateQuotaFromBeforeExplicitRetryCannotBlockTheNewAttempt() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        let network = api(storage), gate = StubProtocol.ResponseGate()
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(503, #"{"error":{"code":"database_read_limit","message":"Quota","resetAt":"2999-01-01T00:00:00Z"}}"#)
            reply.gate = gate; return reply
        }
        let pending = Task { let _: EmptyResponse = try await network.request("/api/glance/old") }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().count == 1 }) else {
            pending.cancel(); gate.release(); _ = try? await pending.value
            XCTFail("Held read did not start"); return
        }
        network.retryQuota(); gate.release()
        do { try await pending.value; XCTFail("The old request must not publish a quota after retry") }
        catch is CancellationError { }
        catch { XCTFail("Expected stale request cancellation, got \(error)") }
        XCTAssertNil(network.quotaBlockedUntil)
    }

    func testSuccessfulConnectionLoadsEachSectionOnceAndAllowsEmptyDiaries() async {
        StubProtocol.state.reset { request in
            .init(request.url?.path == "/api/session" ? #"{"authenticated":true}"# : #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(), store = DiaryStore(api: api(storage))
        await store.connect(credential)
        XCTAssertFalse(store.needsSignIn)
        XCTAssertTrue(store.hasLoadedWorkspace)
        XCTAssertNil(store.error)
        XCTAssertEqual(StubProtocol.state.recorded().count, 5)
        store.signOut()
        XCTAssertTrue(store.needsSignIn)
        XCTAssertFalse(store.hasLoadedWorkspace)
        XCTAssertNil(storage.credential)
    }

    func testSignOutDuringDetachedCachePreparationCannotRestoreACacheOrOldWarning() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: directory, key: SymmetricKey(size: .bits256), beforePrepare: { try gate.holdFirst() })
        StubProtocol.state.reset { _ in .init(#"{"items":[],"next":null}"#) }
        let store = DiaryStore(api: api(storage), cache: cache)
        let refresh = Task { await store.refresh() }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            refresh.cancel(); gate.resume(); await refresh.value; XCTFail("Cache preparation never started"); return
        }
        store.signOut(); gate.resume(); await refresh.value
        XCTAssertTrue(store.needsSignIn); XCTAssertFalse(store.hasLoadedWorkspace)
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertFalse(store.loading)
        XCTAssertNil(store.error); XCTAssertNil(store.cacheWarning)
        XCTAssertNil(cache.load(scope: credential.cacheScope))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testLibraryPresentationIndexReconcilesHistoryLocationsAndSignOutWithTheWorkspace() throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        var workspace = PreviewData.workspace
        let title = try XCTUnwrap(workspace.titles.first { $0.id == "again" })
        store.workspace = workspace
        XCTAssertEqual(store.libraryProgress(title), 0.5)
        XCTAssertTrue(store.hasPresentLocation("frieren"))
        XCTAssertFalse(store.hasPresentLocation("again"))
        let repeated = workspace.events
        workspace.events.append(contentsOf: repeated)
        store.workspace = workspace
        XCTAssertEqual(store.libraryProgress(title), 0.5, "Repeated viewings must not inflate episode progress")
        workspace.events = []; workspace.locations = []
        workspace.titles[0].name = "Reconciled title"
        store.workspace = workspace
        XCTAssertEqual(store.libraryProgress(title), 0)
        XCTAssertFalse(store.hasPresentLocation("frieren"))
        XCTAssertEqual(store.title(workspace.titles[0].id)?.name, "Reconciled title")
        store.signOut()
        XCTAssertNil(store.title(title.id)); XCTAssertEqual(store.libraryProgress(title), 0)
        XCTAssertFalse(store.hasPresentLocation("frieren"))
    }

    func testFailedRefreshPreservesPreviouslyLoadedDiaryAndSession() async {
        StubProtocol.state.reset { _ in .init(503, "Service temporarily unavailable", contentType: "text/plain") }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        store.workspace = PreviewData.workspace; store.hasLoadedWorkspace = true
        let ids = store.workspace.titles.map(\.id)
        await store.refresh()
        XCTAssertFalse(store.needsSignIn)
        XCTAssertTrue(store.hasLoadedWorkspace)
        XCTAssertEqual(store.workspace.titles.map(\.id), ids)
        XCTAssertNotNil(store.error)
    }
    func testFailureInAnyWorkspaceSectionPreservesTheCompleteDiaryAndCachedCopy() async throws {
        let workspace = PreviewData.workspace
        for section in ["titles", "episodes", "events", "locations"] {
            let storage = MemorySessionStorage(); storage.credential = credential
            let cache = MemoryWorkspaceCache()
            try cache.save(workspace, scope: credential.cacheScope, at: .now)
            let store = DiaryStore(api: api(storage), cache: cache)
            StubProtocol.state.reset { request in
                let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
                if query?.first(where: { $0.name == "section" })?.value == section {
                    return .init(503, #"{"error":{"message":"Synthetic section outage"}}"#)
                }
                return .init(#"{"items":[],"next":null}"#)
            }
            await store.refresh()
            let preserved = store.workspace
            XCTAssertEqual(preserved.titles, workspace.titles, section)
            XCTAssertEqual(preserved.episodes, workspace.episodes, section)
            XCTAssertEqual(preserved.events, workspace.events, section)
            XCTAssertEqual(preserved.locations, workspace.locations, section)
            XCTAssertTrue(store.showingCachedSnapshot); XCTAssertTrue(store.hasLoadedWorkspace)
            XCTAssertFalse(store.needsSignIn); XCTAssertFalse(store.loading)
            XCTAssertEqual(store.error, "Synthetic section outage")
            let cached = try XCTUnwrap(cache.load(scope: credential.cacheScope))
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            XCTAssertEqual(try encoder.encode(cached.workspace), try encoder.encode(workspace), section)
        }
    }
    func testWorkspaceSectionsStartTogetherAndPublishOnlyAfterTheResponsesComplete() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace; store.hasLoadedWorkspace = true
        let original = store.workspace.titles, gate = StubProtocol.ResponseGate()
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(#"{"items":[],"next":null}"#)
            reply.gate = gate
            return reply
        }
        let pending = Task { await store.refresh() }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().count == 4 }) else {
            gate.release(); await pending.value
            XCTFail("All four workspace sections must start without waiting for an earlier response")
            return
        }
        XCTAssertEqual(Set(StubProtocol.state.recorded().compactMap { $0.url?.query }),
                       Set(["section=titles", "section=episodes", "section=events", "section=locations"]))
        XCTAssertEqual(store.workspace.titles, original)
        XCTAssertTrue(store.loading)
        gate.release(); await pending.value
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertTrue(store.workspace.episodes.isEmpty)
        XCTAssertTrue(store.workspace.events.isEmpty); XCTAssertTrue(store.workspace.locations.isEmpty)
        XCTAssertTrue(store.hasLoadedWorkspace); XCTAssertFalse(store.loading); XCTAssertNil(store.error)
    }
    func testWorkspacePaginationEscapesTheCursorAndKeepsTheSameAuthenticatedSection() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let cursor = "synthetic &section=events+after/next"
        let envelope: [String: Any] = ["items": [Any](), "next": cursor]
        let first = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        StubProtocol.state.reset { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            return .init(query?.contains(where: { $0.name == "after" }) == true ? #"{"items":[],"next":null}"# : first)
        }
        let items = try await api(storage).allPages("titles", as: MediaTitle.self)
        XCTAssertTrue(items.isEmpty)
        let requests = StubProtocol.state.recorded()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/workspace")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=synthetic-test-session")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.filter { $0.name == "section" }.map(\.value), ["titles"])
        }
        let lastQuery = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(lastQuery?.first(where: { $0.name == "after" })?.value, cursor)
    }
    func testRepeatedWorkspaceCursorFailsWithoutPublishingOrContinuingForever() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init(#"{"items":[],"next":"synthetic-loop"}"#) }
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace; store.hasLoadedWorkspace = true
        await store.refresh()
        XCTAssertEqual(store.error, "The diary returned a repeated page. Please refresh.")
        let requests = StubProtocol.state.recorded()
        let groups = Dictionary(grouping: requests) { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "section" }?.value ?? ""
        }
        XCTAssertTrue(Set(groups.keys).isSubset(of: ["titles", "episodes", "events", "locations"]))
        XCTAssertTrue((2...8).contains(requests.count), "Four concurrent sections may each fetch at most two pages")
        XCTAssertTrue(groups.values.contains { $0.count == 2 }, "At least one section must actually encounter the repeated cursor")
        for pages in groups.values {
            XCTAssertTrue((1...2).contains(pages.count), "No section may continue around the cursor loop: \(pages.map { $0.url?.query ?? "missing-query" })")
            let cursors = pages.map { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value
            }
            XCTAssertNil(cursors.first ?? nil)
            if cursors.count == 2 { XCTAssertEqual(cursors[1], "synthetic-loop") }
        }
        XCTAssertEqual(store.workspace.titles.map(\.id), PreviewData.workspace.titles.map(\.id))
        XCTAssertTrue(store.hasLoadedWorkspace); XCTAssertFalse(store.loading)
    }
    func testPrivateRequestsRejectForeignAndNonAPIPathsBeforeSendingCredentials() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init("{}") }
        let client = api(storage)
        for path in ["https://example.test/api/session", "//example.test/api/session", "/preview/home", "api/session"] {
            do {
                let _: EmptyResponse = try await client.request(path)
                XCTFail("Invalid private request was accepted: " + path)
            } catch {
                XCTAssertEqual(error.localizedDescription, "Invalid diary request.")
            }
        }
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty)
    }

    func testAuthenticationRejectionDoesNotSaveCredential() async {
        StubProtocol.state.reset { _ in .init(401, "Access denied", contentType: "text/plain") }
        let storage = MemorySessionStorage(), store = DiaryStore(api: api(storage))
        await store.connect(credential)
        XCTAssertTrue(store.needsSignIn)
        XCTAssertNil(storage.credential)
        XCTAssertFalse(store.hasLoadedWorkspace)
    }

    func testStorageFailureDoesNotPretendSignInSucceeded() async {
        StubProtocol.state.reset { _ in .init(#"{"authenticated":true}"#) }
        let storage = MemorySessionStorage(); storage.rejectSave = true
        let api = api(storage), store = DiaryStore(api: api)
        await store.connect(credential)
        XCTAssertTrue(store.needsSignIn)
        XCTAssertNil(api.credential)
        XCTAssertNil(storage.credential)
        XCTAssertEqual(store.error, "Test storage unavailable")
    }

    func testTraktThrottlePreservesRetryAfterAndNeverRetriesThePostInsideTransport() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(429, #"{"error":{"code":"trakt_rate_limited","message":"Provider cooldown"}}"#)
            reply.headers["Retry-After"] = "60"; return reply
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        do {
            let _: EmptyResponse = try await api(storage, clock: { date }).request("/api/trakt/sync/fixture/apply", method: "POST", body: ["choice": "apply"])
            XCTFail("Throttle accepted")
        } catch let error as TraktTransferFailure {
            XCTAssertEqual(error.status, 429); XCTAssertEqual(error.code, "trakt_rate_limited")
            XCTAssertEqual(error.retryAt, date.addingTimeInterval(60)); XCTAssertTrue(error.retryable)
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }
    func testTraktPostNetworkLossRequiresReconciliationRatherThanBlindTransportReplay() async {
        StubProtocol.state.reset { _ in var reply = StubProtocol.Reply("{}"); reply.failureCode = .networkConnectionLost; return reply }
        let storage = MemorySessionStorage(); storage.credential = credential
        do {
            let _: EmptyResponse = try await api(storage).request("/api/trakt/sync/fixture/apply", method: "POST", body: ["choice": "apply"])
            XCTFail("Lost response accepted")
        } catch let error as TraktTransferFailure { XCTAssertTrue(error.retryable); XCTAssertEqual(error.status, 0) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }
    func testTraktBootstrapStatusPreservesThrottleAndNetworkFailureEvidence() async {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for offline in [false, true] {
            StubProtocol.state.reset { _ in
                var reply = StubProtocol.Reply(429, #"{"error":{"code":"trakt_rate_limited","message":"Provider cooldown"}}"#)
                reply.headers["Retry-After"] = "120"
                if offline { reply.failureCode = .notConnectedToInternet }
                return reply
            }
            let storage = MemorySessionStorage(); storage.credential = credential
            do {
                let _: TraktStatus = try await api(storage, clock: { date }).request("/api/trakt/status")
                XCTFail("Status failure accepted")
            } catch let error as TraktTransferFailure {
                XCTAssertTrue(error.retryable); XCTAssertEqual(error.status, offline ? 0 : 429)
                XCTAssertEqual(error.retryAt, offline ? nil : date.addingTimeInterval(120))
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(StubProtocol.state.recorded().count, 1)
        }
    }
    func testWriteQuotaParsesResetWithoutSigningOut() async throws {
        StubProtocol.state.reset { _ in
            .init(503, #"{"error":{"code":"database_write_limit","message":"Quota exhausted","resetAt":"2026-10-24T00:00:00Z"}}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let beforeReset = try XCTUnwrap(DiaryDate.parse("2026-10-23T12:00:00Z"))
        do {
            let _: EmptyResponse = try await api(storage, clock: { beforeReset }).request("/api/workspace")
            XCTFail("Expected quota error")
        } catch APIError.databaseLimit(let reset) {
            XCTAssertEqual(reset, ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }
    func testT26JSONForbiddenIsAnApplicationRejectionAndKeepsTheSession() async {
        StubProtocol.state.reset { _ in .init(403, #"{"error":{"message":"Not allowed"}}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        do {
            let _: EmptyResponse = try await store.read("/api/workspace")
            XCTFail("Expected application rejection")
        } catch APIError.rejected(let status, let message) {
            XCTAssertEqual(status, 403); XCTAssertEqual(message, "Not allowed")
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(store.needsSignIn); XCTAssertNotNil(storage.credential)
    }
    func testT26HTMLForbiddenRequiresSignInButNotModifiedDoesNot() async {
        for status in [304, 403] {
            StubProtocol.state.reset { _ in .init(status, "", contentType: "text/html") }
            let storage = MemorySessionStorage(); storage.credential = credential
            let store = DiaryStore(api: api(storage))
            do {
                let _: EmptyResponse = try await store.read("/api/workspace")
                XCTFail("Expected typed status")
            } catch APIError.notModified { XCTAssertEqual(status, 304) }
            catch APIError.signIn { XCTAssertEqual(status, 403) }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(store.needsSignIn, status == 403)
        }
    }

    func testUnexpectedSuccessfulHTMLIsNotReportedAsExpiredSession() async {
        StubProtocol.state.reset { _ in .init(200, "<html>Unavailable</html>", contentType: "text/html") }
        let storage = MemorySessionStorage(); storage.credential = credential
        do {
            let _: EmptyResponse = try await api(storage).request("/api/workspace")
            XCTFail("Expected response error")
        } catch APIError.message(let message) {
            XCTAssertTrue(message.contains("unexpected response"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }
    func testHTTPFallbackDistinguishesAFailedReadFromAnUnconfirmedWrite() async {
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init(503, "Synthetic offline", contentType: "text/plain") }
        let client = api(storage)
        for (method, expected) in [
            ("GET", "The diary could not be loaded. Please try refreshing."),
            ("PATCH", "The change was not confirmed. Refresh before trying again.")
        ] {
            do {
                let _: EmptyResponse = try await client.request("/api/titles/synthetic", method: method)
                XCTFail("The failing transport was accepted")
            } catch APIError.rejected(let status, let message) {
                XCTAssertEqual(status, 503); XCTAssertEqual(message, expected)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }
    func testCachedDiaryRestoresOnlyForCurrentSessionAndSignOutErasesIt() async throws {
        let cache = MemoryWorkspaceCache()
        try cache.save(PreviewData.workspace, scope: credential.cacheScope, at: .now)
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage), cache: cache)
        XCTAssertTrue(store.hasLoadedWorkspace); XCTAssertTrue(store.showingCachedSnapshot)
        XCTAssertEqual(store.workspace.titles.count, PreviewData.workspace.titles.count)
        StubProtocol.state.reset { _ in .init(503, "Offline", contentType: "text/plain") }
        await store.refresh()
        XCTAssertTrue(store.showingCachedSnapshot)
        XCTAssertFalse(store.workspace.titles.isEmpty)
        store.signOut()
        XCTAssertTrue(store.workspace.titles.isEmpty)
        XCTAssertNil(cache.load(scope: credential.cacheScope))
    }
    func testProtectedColdCacheRestoresBeforeAnOfflineRefreshWithoutBlockingInitialization() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforeLoad: { try gate.holdFirst() })
        try cache.save(PreviewData.workspace, scope: credential.cacheScope, at: .now)
        let storage = MemorySessionStorage(); storage.credential = credential
        StubProtocol.state.reset { _ in .init(503, "Synthetic offline", contentType: "text/plain") }
        let store = DiaryStore(api: api(storage), cache: cache)
        XCTAssertFalse(store.hasLoadedWorkspace); XCTAssertTrue(store.restoringCache)
        let refresh = Task { await store.refresh() }
        guard await waitForRegressionCondition({ gate.hasStarted }) else {
            refresh.cancel(); gate.resume(); await refresh.value; XCTFail("Cold restore never started"); return
        }
        XCTAssertFalse(gate.startedOnMainThread)
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty, "Refresh must await the single cold restore")
        gate.resume(); await refresh.value
        XCTAssertEqual(store.workspace.titles, PreviewData.workspace.titles)
        XCTAssertTrue(store.hasLoadedWorkspace); XCTAssertTrue(store.showingCachedSnapshot)
        XCTAssertFalse(store.restoringCache); XCTAssertFalse(store.loading)
        XCTAssertFalse(store.needsSignIn)
    }

    func testSignOutDuringColdCacheRestorationCannotResurrectTheDiary() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforeLoad: { try gate.holdFirst() })
        try cache.save(PreviewData.workspace, scope: credential.cacheScope, at: .now)
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage), cache: cache)
        let refresh = Task { await store.refresh() }
        guard await waitForRegressionCondition({ gate.hasStarted && store.loading }) else {
            refresh.cancel(); gate.resume(); await refresh.value; XCTFail("Cold restore never started"); return
        }
        store.signOut(); gate.resume(); await refresh.value
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertTrue(store.needsSignIn)
        XCTAssertFalse(store.hasLoadedWorkspace); XCTAssertFalse(store.restoringCache); XCTAssertFalse(store.loading)
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAccountChangeDuringColdRestorationRejectsThePreviousOwnersSnapshot() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = CachePreparationGate()
        let cache = ProtectedWorkspaceCache(directory: folder, key: SymmetricKey(size: .bits256), beforeLoad: { try gate.holdFirst() })
        try cache.save(PreviewData.workspace, scope: credential.cacheScope, at: .now)
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage), cache: cache)
        let oldRefresh = Task { await store.refresh() }
        guard await waitForRegressionCondition({ gate.hasStarted && store.loading }) else {
            oldRefresh.cancel(); gate.resume(); await oldRefresh.value; XCTFail("Cold restore never started"); return
        }
        StubProtocol.state.reset { request in
            .init(request.url?.path == "/api/session" ? #"{"authenticated":true}"# : #"{"items":[],"next":null}"#)
        }
        await store.connect(AccessCredential(token: "synthetic-other-owner", expires: .distantFuture))
        gate.resume(); await oldRefresh.value
        XCTAssertEqual(storage.credential?.token, "synthetic-other-owner")
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertTrue(store.hasLoadedWorkspace)
        XCTAssertFalse(store.showingCachedSnapshot); XCTAssertFalse(store.needsSignIn); XCTAssertFalse(store.restoringCache)
    }
    func testSignOutWhileLoadingCannotResurrectSessionOrDiary() async throws {
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(#"{"items":[],"next":null}"#); reply.delay = 0.15; return reply
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let cache = MemoryWorkspaceCache(), store = DiaryStore(api: api(storage), cache: cache)
        let refresh = Task { await store.refresh() }
        for _ in 0..<100 {
            if !StubProtocol.state.recorded().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(StubProtocol.state.recorded().isEmpty)
        store.signOut(); await refresh.value
        XCTAssertTrue(store.needsSignIn)
        XCTAssertFalse(store.hasLoadedWorkspace)
        XCTAssertTrue(store.workspace.titles.isEmpty)
        XCTAssertNil(cache.load(scope: credential.cacheScope))
        XCTAssertNil(storage.credential)
    }
    func testSignOutDuringAuthenticationCannotSaveALateCredential() async throws {
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(#"{"authenticated":true}"#); reply.delay = 0.15; return reply
        }
        let storage = MemorySessionStorage(), store = DiaryStore(api: api(storage))
        let connection = Task { await store.connect(credential) }
        for _ in 0..<100 {
            if !StubProtocol.state.recorded().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.signOut(); await connection.value
        XCTAssertTrue(store.needsSignIn)
        XCTAssertNil(storage.credential)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }
    func testSlowerRefreshCannotOverwriteNewerCompleteSnapshot() async throws {
        let original = PreviewData.workspace.titles
        var edited = original; edited[0].name = "Newer confirmed title"
        func page(_ titles: [MediaTitle]) throws -> String {
            let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(titles))
            return String(decoding: try JSONSerialization.data(withJSONObject: ["items": items, "next": NSNull()]), as: UTF8.self)
        }
        let oldPage = try page(original), newPage = try page(edited)
        StubProtocol.state.reset { request in
            if request.url?.query == "section=titles" {
                let first = StubProtocol.state.recorded().filter { $0.url?.query == "section=titles" }.count == 1
                var reply = StubProtocol.Reply(first ? oldPage : newPage)
                if first { reply.delay = 0.2 }
                return reply
            }
            return .init(#"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        let earlier = Task { await store.refresh() }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().contains { $0.url?.query == "section=titles" } }) else {
            earlier.cancel(); await earlier.value; XCTFail("The delayed title section did not start"); return
        }
        try await store.reload(); await earlier.value
        XCTAssertEqual(store.workspace.titles.first?.name, "Newer confirmed title")
        XCTAssertTrue(store.hasLoadedWorkspace)
        XCTAssertNil(store.error)
    }
    func testEpisodeToggleUsesEpisodeIdentityAndRetainsUndoReceipt() async throws {
        let workspace = PreviewData.workspace
        let title = try XCTUnwrap(workspace.titles.first { $0.id == "again" })
        let episode = try XCTUnwrap(workspace.episodes.first { $0.titleId == title.id && $0.number == 9 })
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
        let event: [String: Any] = ["id": "fixture-new-watch", "operationId": "fixture-operation", "titleId": title.id, "episodeId": episode.id, "watchedAt": date.ISO8601Format(), "recordedAt": date.ISO8601Format(), "revokedAt": NSNull(), "origin": "manual", "version": 1]
        let receipt = String(decoding: try JSONSerialization.data(withJSONObject: ["event": event, "added": true]), as: UTF8.self)
        let pages = try workspacePages(workspace)
        StubProtocol.state.reset { request in
            if request.httpMethod == "POST" { return .init(receipt) }
            if request.httpMethod == "PATCH" { return .init(receipt) }
            return .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let success = await store.recordViewing(title, episode: episode, watchedAt: date)
        XCTAssertTrue(success); XCTAssertEqual(store.undoLabel, "Watch marked")
        let write = try XCTUnwrap(StubProtocol.state.recorded().first { $0.httpMethod == "POST" })
        let body = try bodyObject(write)
        XCTAssertEqual(body["episodeId"] as? String, episode.id)
        XCTAssertEqual(body["rewatch"] as? Bool, false)
        await store.undo()
        XCTAssertNil(store.undoLabel)
        XCTAssertEqual(StubProtocol.state.recorded().filter { $0.httpMethod == "PATCH" }.map { $0.url?.path }, ["/api/watch-events/fixture-new-watch"])
    }
    func testUncertainViewingRetryKeepsItsOperationIdentityAndOriginalDate() async throws {
        let workspace = PreviewData.workspace, title = try XCTUnwrap(PreviewData.workspace.titles.first { !$0.isSeries })
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z"))
        let event: [String: Any] = ["id": "fixture-viewing", "operationId": "fixture-operation", "titleId": title.id, "episodeId": NSNull(), "watchedAt": date.ISO8601Format(), "recordedAt": date.ISO8601Format(), "revokedAt": NSNull(), "origin": "manual", "version": 1]
        let receipt = String(decoding: try JSONSerialization.data(withJSONObject: ["event": event, "added": true]), as: UTF8.self)
        let pages = try workspacePages(workspace)
        StubProtocol.state.reset { request in
            if request.httpMethod == "POST" {
                return StubProtocol.state.recorded().filter { $0.httpMethod == "POST" }.count == 1 ? .init(503, #"{"error":{"message":"Response uncertain"}}"#) : .init(receipt)
            }
            return .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let first = await store.recordViewing(title, rewatch: true, watchedAt: date)
        XCTAssertFalse(first)
        let second = await store.recordViewing(title, rewatch: true, watchedAt: date.addingTimeInterval(1))
        XCTAssertTrue(second)
        let writes = StubProtocol.state.recorded().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 2)
        let firstBody = try bodyObject(writes[0]), secondBody = try bodyObject(writes[1])
        XCTAssertEqual(firstBody["operationId"] as? String, secondBody["operationId"] as? String)
        XCTAssertEqual(firstBody["watchedAt"] as? String, secondBody["watchedAt"] as? String)
        XCTAssertEqual(secondBody["rewatch"] as? Bool, true)
    }
    func testT35NormalWatchAndRewatchUseDifferentStablePendingOperations() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace
        let title = try XCTUnwrap(store.workspace.titles.first { !$0.isSeries })
        StubProtocol.state.reset { _ in .init(503, #"{"error":{"message":"Uncertain response"}}"#) }
        _ = await store.recordViewing(title, rewatch: false, watchedAt: .now)
        _ = await store.recordViewing(title, rewatch: true, watchedAt: .now)
        _ = await store.recordViewing(title, rewatch: true, watchedAt: .now.addingTimeInterval(-1))
        let writes = StubProtocol.state.recorded().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 3)
        guard writes.count == 3 else { return }
        let normal = try bodyObject(writes[0]), rewatch = try bodyObject(writes[1]), retry = try bodyObject(writes[2])
        XCTAssertEqual(normal["rewatch"] as? Bool, false); XCTAssertEqual(rewatch["rewatch"] as? Bool, true)
        XCTAssertNotEqual(normal["operationId"] as? String, rewatch["operationId"] as? String)
        XCTAssertEqual(rewatch["operationId"] as? String, retry["operationId"] as? String)
        XCTAssertEqual(rewatch["watchedAt"] as? String, retry["watchedAt"] as? String)
    }
    func testConfirmedRewatchRefreshFailureAcknowledgesSaveAndBlocksAnotherWriteUntilReconciled() async throws {
        let workspace = PreviewData.workspace
        let title = try XCTUnwrap(workspace.titles.first { !$0.isSeries })
        let date = try XCTUnwrap(DiaryDate.parse("2026-10-23T12:00:00Z"))
        let eventObject: [String: Any] = [
            "id": "confirmed-rewatch", "operationId": "confirmed-operation", "titleId": title.id,
            "episodeId": NSNull(), "watchedAt": "2026-10-23T12:00:00Z", "recordedAt": "2026-10-23T12:00:00Z",
            "revokedAt": NSNull(), "origin": "manual", "version": 1
        ]
        let event = try JSONDecoder().decode(WatchEvent.self, from: JSONSerialization.data(withJSONObject: eventObject))
        let receipt = String(decoding: try JSONSerialization.data(withJSONObject: ["event": eventObject, "added": true]), as: UTF8.self)
        StubProtocol.state.reset { request in
            if request.httpMethod == "POST" { return .init(receipt) }
            return .init(503, #"{"error":{"message":"Synthetic refresh outage"}}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let saved = await store.recordViewing(title, rewatch: true, watchedAt: date)
        XCTAssertTrue(saved, "A confirmed POST must not become an unconfirmed write because a subsequent GET fails")
        XCTAssertNil(store.error); XCTAssertNotNil(store.mutationRefreshNotice)
        XCTAssertTrue(store.needsMutationRefresh); XCTAssertTrue(store.writesBlocked); XCTAssertFalse(store.canMutate)
        XCTAssertEqual(store.undoLabel, "Watch marked"); XCTAssertFalse(store.busy)
        XCTAssertEqual(store.workspace.events.map(\.id), workspace.events.map(\.id))
        let repeated = await store.recordViewing(title, rewatch: true, watchedAt: date)
        XCTAssertFalse(repeated)
        await store.undo()
        XCTAssertEqual(StubProtocol.state.recorded().filter { $0.httpMethod != "GET" }.count, 1)
        let refreshes = StubProtocol.state.recorded().filter { $0.url?.path == "/api/workspace" }
        XCTAssertTrue((1...4).contains(refreshes.count))
        XCTAssertEqual(Set(refreshes.compactMap { $0.url?.query }).count, refreshes.count,
                       "Do not silently repeat any section after acknowledging a confirmed write")
        var reconciled = workspace; reconciled.events.append(event)
        let pages = try workspacePages(reconciled)
        StubProtocol.state.reset { request in
            if request.httpMethod == "PATCH" { return .init(receipt) }
            return .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#)
        }
        await store.refresh()
        XCTAssertFalse(store.needsMutationRefresh); XCTAssertFalse(store.writesBlocked); XCTAssertTrue(store.canMutate)
        XCTAssertNil(store.mutationRefreshNotice); XCTAssertNil(store.error)
        XCTAssertEqual(store.workspace.events.filter { $0.id == event.id }.count, 1)
        XCTAssertTrue(StubProtocol.state.recorded().allSatisfy { $0.httpMethod == "GET" })
        await store.undo()
        XCTAssertEqual(StubProtocol.state.recorded().filter { $0.httpMethod == "PATCH" }.map { $0.url?.path }, ["/api/watch-events/confirmed-rewatch"])
        XCTAssertNil(store.undoLabel)
    }
    func testConfirmedPatchWithRejectedRefreshKeepsSaveReceiptAndRequestsSignIn() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let workspace = PreviewData.workspace, title = try XCTUnwrap(PreviewData.workspace.titles.first)
        StubProtocol.state.reset { request in
            request.httpMethod == "PATCH" ? .init("{}") : .init(401, "Sign in", contentType: "text/plain")
        }
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let saved = await store.patch(title, values: ["favorite": !title.favorite])
        XCTAssertTrue(saved); XCTAssertTrue(store.needsSignIn); XCTAssertTrue(store.needsMutationRefresh)
        XCTAssertNotNil(store.mutationRefreshNotice); XCTAssertFalse(store.busy)
        XCTAssertEqual(StubProtocol.state.recorded().first?.httpMethod, "PATCH")
        XCTAssertTrue(StubProtocol.state.recorded().dropFirst().allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue((2...5).contains(StubProtocol.state.recorded().count))
        store.signOut()
        XCTAssertFalse(store.needsMutationRefresh); XCTAssertNil(store.mutationRefreshNotice)
        XCTAssertNil(store.undoLabel); XCTAssertTrue(store.workspace.titles.isEmpty)
    }
    func testFailedReconciliationRetainsTheWriteGateAndOldCompleteWorkspace() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace; store.hasLoadedWorkspace = true
        StubProtocol.state.reset { request in
            request.httpMethod == "PATCH" ? .init("{}") : .init(503, #"{"error":{"message":"Synthetic offline"}}"#)
        }
        let title = try XCTUnwrap(store.workspace.titles.first)
        let saved = await store.patch(title, values: ["notes": "Confirmed server note"])
        XCTAssertTrue(saved)
        await store.refresh()
        XCTAssertTrue(store.needsMutationRefresh); XCTAssertNotNil(store.mutationRefreshNotice)
        XCTAssertEqual(store.workspace.titles.first?.notes, title.notes)
        XCTAssertEqual(StubProtocol.state.recorded().filter { $0.httpMethod == "PATCH" }.count, 1)
    }
    func testTitleScopedWriteRefreshesOnlyThatTitleWithoutAFullDiaryRead() async throws {
        let workspace = PreviewData.workspace
        let title = try XCTUnwrap(workspace.titles.first { $0.id == "again" })
        let ownEvents = workspace.events.filter { $0.titleId == title.id }
        let removed = try XCTUnwrap(ownEvents.last)
        // The server's view after the write: only this title's rows differ.
        let refreshed: [String: Any] = [
            "ids": [title.id],
            "titles": try JSONSerialization.jsonObject(with: JSONEncoder().encode([title])),
            "episodes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.episodes.filter { $0.titleId == title.id })),
            "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ownEvents.filter { $0.id != removed.id })),
            "locations": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.locations.filter { $0.titleId == title.id }))
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: refreshed), as: UTF8.self)
        StubProtocol.state.reset { request in
            if request.httpMethod == "PATCH" { return .init("{}") }
            if request.url?.path == "/api/workspace/titles" { return .init(body) }
            return .init(503, #"{"error":{"message":"A complete diary read is not expected"}}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let saved = await store.patch(title, values: ["favorite": !title.favorite])
        XCTAssertTrue(saved); XCTAssertFalse(store.needsMutationRefresh); XCTAssertNil(store.error)
        let reads = StubProtocol.state.recorded().filter { $0.httpMethod == "GET" }
        XCTAssertEqual(reads.map { $0.url?.path }, ["/api/workspace/titles"])
        let query = URLComponents(url: try XCTUnwrap(reads.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "ids" }?.value, title.id)
        XCTAssertEqual(Set(store.workspace.events.map(\.id)), Set(workspace.events.map(\.id)).subtracting([removed.id]))
        XCTAssertEqual(store.workspace.events.count, workspace.events.count - 1)
        XCTAssertEqual(Set(store.workspace.titles.map(\.id)), Set(workspace.titles.map(\.id)))
        XCTAssertEqual(Set(store.workspace.episodes.map(\.id)), Set(workspace.episodes.map(\.id)))
        XCTAssertEqual(Set(store.workspace.locations.map(\.id)), Set(workspace.locations.map(\.id)))
    }
    func testTargetedRefreshThatOmitsARequestedTitleFallsBackToTheCompleteRead() async throws {
        let workspace = PreviewData.workspace
        let title = try XCTUnwrap(workspace.titles.first { $0.id == "again" })
        let pages = try workspacePages(workspace)
        StubProtocol.state.reset { request in
            if request.httpMethod == "PATCH" { return .init("{}") }
            if request.url?.path == "/api/workspace/titles" {
                return .init(#"{"ids":["someone-else"],"titles":[],"episodes":[],"events":[],"locations":[]}"#)
            }
            return .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let saved = await store.patch(title, values: ["favorite": !title.favorite])
        XCTAssertTrue(saved); XCTAssertFalse(store.needsMutationRefresh)
        let full = StubProtocol.state.recorded().filter { $0.url?.path == "/api/workspace" }
        XCTAssertEqual(full.count, 4, "An inconsistent targeted read must be replaced by one complete snapshot")
        XCTAssertEqual(Set(store.workspace.titles.map(\.id)), Set(workspace.titles.map(\.id)))
    }
    func testSignOutDuringConfirmedWriteRefreshCannotRestoreTheSaveNoticeOrWorkspace() async throws {
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace; store.hasLoadedWorkspace = true
        let title = try XCTUnwrap(store.workspace.titles.first)
        StubProtocol.state.reset { request in
            if request.httpMethod == "PATCH" { return .init("{}") }
            var reply = StubProtocol.Reply(#"{"items":[],"next":null}"#); reply.delay = 0.15
            return reply
        }
        let saving = Task { await store.patch(title, values: ["favorite": !title.favorite]) }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().contains { $0.httpMethod == "GET" } }) else {
            saving.cancel(); XCTFail("The confirmed write did not reach its refresh"); return
        }
        store.signOut()
        let savedForCurrentSession = await saving.value
        XCTAssertFalse(savedForCurrentSession)
        XCTAssertFalse(store.needsMutationRefresh); XCTAssertNil(store.mutationRefreshNotice)
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertNil(store.error)
        XCTAssertFalse(store.busy); XCTAssertTrue(store.needsSignIn)
    }
    func testRemovingLatestRejectsChangedDisplayedEventBeforeAnyWrite() async throws {
        let workspace = PreviewData.workspace, title = try XCTUnwrap(PreviewData.workspace.titles.first { $0.id == "again" })
        let displayed = PreviewData.card(title, workspace: workspace).previous
        StubProtocol.state.reset { _ in .init(#"{"progress":{"watched":9,"total":16},"previous":{"id":"different-watch","version":1,"episodeId":"different-episode","number":9},"next":null,"season":null}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        await store.removeLatest(title, expected: displayed)
        XCTAssertTrue(store.error?.contains("history changed") == true)
        XCTAssertFalse(StubProtocol.state.recorded().contains { $0.httpMethod == "PATCH" })
    }
    func testTraktWireContractCarriesEveryExplicitDirectionChoice() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "trakt-sync", withExtension: "json"))
        let response = try String(contentsOf: url, encoding: .utf8)
        StubProtocol.state.reset { _ in .init(response) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let owner = DiaryStore(api: api(storage))
        defer { withExtendedLifetime(owner) {} }
        let service = LiveTraktService(store: owner)
        for choice in [TraktChoice.apply, .local, .trakt, .skip] {
            _ = try await service.apply(id: "fixture-run", change: "fixture-change", choice: choice)
        }
        let writes = StubProtocol.state.recorded()
        XCTAssertEqual(writes.count, 4)
        let bodies = try writes.map(bodyObject)
        XCTAssertEqual(bodies.map { $0["choice"] as? String }, ["apply", "local", "trakt", "skip"])
        XCTAssertTrue(writes.allSatisfy { $0.url?.path == "/api/trakt/sync/fixture-run/apply" && $0.httpMethod == "POST" })
        XCTAssertTrue(bodies.allSatisfy { $0["changeId"] as? String == "fixture-change" })
    }
    func testRetainedTraktControllerDoesNotKeepItsDiarySessionAlive() async {
        StubProtocol.state.reset { _ in .init(#"{"configured":true,"connected":true}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        weak var released: DiaryStore?
        var controller: TraktController?
        do {
            let owner = DiaryStore(api: api(storage)); released = owner
            controller = owner.traktController
        }
        XCTAssertNil(released, "The retained transfer must not form a store/service ownership cycle")
        await controller?.refresh()
        XCTAssertNil(controller?.status)
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty, "A released owner cannot issue a request")
    }
    func testBulkCollectionUsesOneAtomicRequestWithFrozenReviewedVersions() async throws {
        let workspace = PreviewData.workspace, reviewed = Array(PreviewData.workspace.activeTitles.prefix(2))
        let pages = try workspacePages(workspace)
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["ids": reviewed.map(\.id), "count": reviewed.count, "action": "queue"]), as: UTF8.self)
        StubProtocol.state.reset { request in
            if request.httpMethod == "POST" { return .init(response) }
            return .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let success = await store.manage(reviewed, change: .queue(true))
        XCTAssertTrue(success)
        let writes = StubProtocol.state.recorded().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?.url?.path, "/api/titles/bulk")
        let body = try bodyObject(XCTUnwrap(writes.first))
        XCTAssertEqual(Set(body.keys), ["action", "items", "queued"])
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, reviewed.map(\.id))
        XCTAssertEqual(items.compactMap { $0["expectedVersion"] as? Int }, reviewed.compactMap(\.version))
    }
    func testBulkResetRetriesItsOriginalOperationAndUsesProgressUndoEndpoint() async throws {
        let workspace = PreviewData.workspace, reviewed = Array(PreviewData.workspace.activeTitles.prefix(2))
        let pages = try workspacePages(workspace)
        StubProtocol.state.reset { request in
            if request.httpMethod == "POST" {
                let count = StubProtocol.state.recorded().filter { $0.httpMethod == "POST" }.count
                if count == 1 { return .init(503, #"{"error":{"message":"Unconfirmed progress"}}"#) }
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let json: [String: Any] = ["operationId": body?["operationId"] as? String ?? "invalid"]
                return .init(String(decoding: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(), as: UTF8.self))
            }
            return .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace; store.hasLoadedWorkspace = true
        let first = await store.manage(reviewed, change: .status("planned"))
        XCTAssertFalse(first)
        let second = await store.manage(reviewed, change: .status("planned"))
        XCTAssertTrue(second); XCTAssertEqual(store.undoLabel, "Progress reset")
        var writes = StubProtocol.state.recorded().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 2)
        let a = try bodyObject(writes[0]), b = try bodyObject(writes[1])
        XCTAssertEqual(a["operationId"] as? String, b["operationId"] as? String)
        XCTAssertEqual(a["watchedAt"] as? String, b["watchedAt"] as? String)
        XCTAssertTrue(writes.allSatisfy { $0.url?.path == "/api/progress/status" })
        await store.undo(); XCTAssertNil(store.undoLabel)
        writes = StubProtocol.state.recorded().filter { $0.httpMethod == "POST" }
        XCTAssertEqual(writes.count, 3)
        let undo = try bodyObject(writes[2])
        XCTAssertEqual(undo["undoOf"] as? String, b["operationId"] as? String)
        XCTAssertNotEqual(undo["operationId"] as? String, undo["undoOf"] as? String)
    }
    func testUnifiedSearchUsesExistingDiaryEndpointAndPreservesProviderFailureAsPartialData() async throws {
        StubProtocol.state.reset { _ in .init(#"{"library":[{"id":"known","name":"Identity match","year":2020,"category":"show","posterPath":null}],"online":[],"page":2,"totalPages":4,"onlineError":"Online search temporarily unavailable"}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        let result = try await store.searchDiary(DiarySearchTools.normalize("https://imdb.com/title/TT1234567/"), page: 2)
        XCTAssertEqual(result.library.first?.id, "known"); XCTAssertEqual(result.page, 2); XCTAssertFalse(result.onlineError.isEmpty)
        let request = try XCTUnwrap(StubProtocol.state.recorded().first)
        XCTAssertEqual(request.url?.path, "/api/search")
        let parts = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["q": "tt1234567", "scope": "online", "page": "2"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=synthetic-test-session")
    }
    func testDiscoveryCacheUsesCompleteQueryAndCannotServeAfterSignOut() async throws {
        StubProtocol.state.reset { _ in .init(#"{"items":[],"page":1,"totalPages":1}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)), query = DiscoveryFilters(section: .ratedShows).query(section: .ratedShows)
        let service = LiveDiscoveryService(store: store)
        _ = try await service.page(query); _ = try await service.page(query)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
        _ = try await service.page(DiscoveryFilters(section: .ratedMovies).query(section: .ratedMovies))
        XCTAssertEqual(StubProtocol.state.recorded().count, 2)
        store.signOut()
        do { _ = try await service.page(query); XCTFail("Signed-out discovery must not open cached private data") }
        catch { XCTAssertTrue(store.needsSignIn) }
        XCTAssertEqual(StubProtocol.state.recorded().count, 2)
    }
    func testSignOutDiscardsLateProgressCardWithoutPublishingAnError() async throws {
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(#"{"progress":{"watched":1,"total":16},"season":null,"next":null,"previous":null}"#)
            reply.delay = 0.15; return reply
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)), title = try XCTUnwrap(PreviewData.workspace.activeTitles.first)
        let pending = Task { () -> Bool in
            do { _ = try await store.card(title); return true }
            catch is CancellationError { return false }
            catch { XCTFail("Expected session cancellation, received \(error)"); return false }
        }
        for _ in 0..<100 {
            if !StubProtocol.state.recorded().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.signOut()
        let accepted = await pending.value
        XCTAssertFalse(accepted); XCTAssertTrue(store.needsSignIn); XCTAssertNil(store.error)
    }
    func testLateUnauthorizedReadAfterSignOutIsCancellationNotANewLoginError() async throws {
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(401, #"{"error":{"message":"Expired synthetic session"}}"#)
            reply.delay = 0.15; return reply
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        let pending = Task { () -> Bool in
            do { let _: EmptyResponse = try await store.read("/api/metadata/status"); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        for _ in 0..<100 {
            if !StubProtocol.state.recorded().isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.signOut()
        let cancelled = await pending.value
        XCTAssertTrue(cancelled); XCTAssertTrue(store.needsSignIn); XCTAssertNil(store.error)
    }
    func testPublicRatingsUseExistingEndpointAndKeepProviderFailureOutOfTheGlobalError() async throws {
        StubProtocol.state.reset { _ in .init(503, #"{"error":{"message":"Synthetic provider unavailable"}}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)), title = try XCTUnwrap(PreviewData.workspace.activeTitles.first)
        await store.loadPublicRatings([title, title], source: .tmdb)
        XCTAssertTrue(StubProtocol.state.recorded().isEmpty)
        await store.loadPublicRatings([title, title], source: .trakt)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
        XCTAssertEqual(StubProtocol.state.recorded().first?.url?.path, "/api/library/ratings")
        XCTAssertEqual(StubProtocol.state.recorded().first?.timeoutInterval, 8)
        XCTAssertEqual(store.communityRatings.entries[title.id]?.state, "unavailable")
        XCTAssertNil(store.error); XCTAssertFalse(store.needsSignIn)
        await store.loadPublicRatings([title], source: .trakt)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }
    func testSignOutClearsPublicScoresAndIgnoresLateProviderResponse() async throws {
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(#"{"source":"trakt","ratings":{"again":{"score":7.7,"state":"rated"}}}"#)
            reply.delay = 0.15; return reply
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)), title = try XCTUnwrap(PreviewData.workspace.activeTitles.first { $0.id == "again" })
        let pending = Task { await store.loadPublicRatings([title], source: .trakt) }
        for _ in 0..<100 { if !StubProtocol.state.recorded().isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        store.signOut(); await pending.value
        XCTAssertTrue(store.communityRatings.entries.isEmpty); XCTAssertFalse(store.communityRatings.loading)
        XCTAssertNil(store.error)
        await store.loadPublicRatings([title], source: .trakt)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }
    func testDifferentAccountCannotKeepThePreviousWorkspaceWhenItsReloadFails() async throws {
        let cache = MemoryWorkspaceCache()
        try cache.save(PreviewData.workspace, scope: credential.cacheScope, at: .now)
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage), cache: cache)
        XCTAssertFalse(store.workspace.titles.isEmpty)
        StubProtocol.state.reset { request in
            request.url?.path == "/api/session" ? .init(#"{"authenticated":true}"#) : .init(503, #"{"error":{"message":"Synthetic offline"}}"#)
        }
        await store.connect(AccessCredential(token: "synthetic-other-owner", expires: .distantFuture))
        XCTAssertFalse(store.needsSignIn); XCTAssertFalse(store.hasLoadedWorkspace)
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertFalse(store.showingCachedSnapshot)
        XCTAssertNil(store.lastRefreshedAt); XCTAssertNil(store.undoLabel)
        XCTAssertEqual(storage.credential?.token, "synthetic-other-owner")
        XCTAssertNotNil(cache.load(scope: credential.cacheScope), "Owner-scoped encrypted copies may remain, but must never be published for a different account")
    }
    func testDiscoveryCannotReusePreviousSessionsRecommendationCacheAfterReconnect() async throws {
        StubProtocol.state.reset { request in
            if request.url?.path == "/api/session" { return .init(#"{"authenticated":true}"#) }
            if request.url?.path == "/api/workspace" { return .init(#"{"items":[],"next":null}"#) }
            return .init(#"{"items":[],"page":1,"totalPages":1}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)), service = LiveDiscoveryService(store: store)
        let query = DiscoveryFilters(section: .recommended).query(section: .recommended)
        _ = try await service.page(query)
        await store.connect(AccessCredential(token: "synthetic-other-owner", expires: .distantFuture))
        _ = try await service.page(query)
        let pages = StubProtocol.state.recorded().filter { $0.url?.path == "/api/discovery" }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.last?.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=synthetic-other-owner")
    }
    func testPersonMetadataUsesBoundedSharedCacheAndNeverSurvivesSignOut() async throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "catalog-person", withExtension: "json")))
        let json = String(decoding: data, as: UTF8.self)
        StubProtocol.state.reset { _ in .init(json) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        _ = try await store.person(700001); _ = try await store.person(700001)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
        for id in 700002...700034 { _ = try await store.person(id) }
        XCTAssertEqual(store.cachedPeople.count, 32); XCTAssertNil(store.cachedPeople[700001])
        store.signOut(); XCTAssertTrue(store.cachedPeople.isEmpty)
        do { _ = try await store.person(700034); XCTFail("A signed-out view cannot read cached metadata") } catch { XCTAssertTrue(store.needsSignIn) }
        XCTAssertEqual(StubProtocol.state.recorded().count, 34)
    }
    func testProgressCardsShareReadsRetainCategoryCacheAndInvalidateOnlyTheirOwnTitle() async throws {
        StubProtocol.state.reset { _ in
            var reply = StubProtocol.Reply(#"{"progress":{"watched":8,"total":16},"season":{"number":1,"name":"Season 1"},"next":{"id":"again-9","number":9},"previous":null}"#)
            reply.delay = 0.03; return reply
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace
        let title = try XCTUnwrap(store.title("again"))
        let revision = store.cardRevision(title.id)
        async let first = store.card(title)
        async let second = store.card(title)
        _ = try await (first, second)
        _ = try await store.card(title)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1, "Home, Glance and returning categories should share one current read")
        let unrelated = try XCTUnwrap(store.workspace.titles.firstIndex { $0.id != title.id })
        store.workspace.titles[unrelated].notes += " unrelated edit"
        XCTAssertEqual(store.cardRevision(title.id), revision)
        _ = try await store.card(title)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
        let own = try XCTUnwrap(store.workspace.titles.firstIndex { $0.id == title.id })
        store.workspace.titles[own].notes += " own edit"
        XCTAssertNotEqual(store.cardRevision(title.id), revision)
        _ = try await store.card(try XCTUnwrap(store.title(title.id)))
        XCTAssertEqual(StubProtocol.state.recorded().count, 2)
        _ = try await store.card(title, fresh: true)
        XCTAssertEqual(StubProtocol.state.recorded().count, 3, "Writes must revalidate progress rather than trusting the display cache")
        store.signOut()
        do { _ = try await store.card(title); XCTFail("A signed-out card read must not return a cached score") } catch { }
        XCTAssertEqual(StubProtocol.state.recorded().count, 3)
    }
    func testDifferentCardMutationsQueueWithoutDimmingOrDroppingOtherCardsAndDeduplicateSameCard() async throws {
        let pages = try workspacePages(PreviewData.workspace)
        StubProtocol.state.reset { request in .init(pages[request.url?.query ?? ""] ?? "{}") }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        var gate: CheckedContinuation<Void, Never>?
        var secondRan = false
        let first = Task { await store.perform(cardID: "again", cardAction: .mark) { await withCheckedContinuation { gate = $0 } } }
        guard await waitForRegressionCondition({ gate != nil }) else { first.cancel(); XCTFail("First mutation did not start"); return }
        let second = Task { await store.perform(cardID: "frieren", cardAction: .remove) { secondRan = true } }
        guard await waitForRegressionCondition({ store.cardActions["frieren"] == .remove }) else { gate?.resume(); _ = await first.value; second.cancel(); XCTFail("Second card did not queue"); return }
        XCTAssertEqual(store.cardActions["again"], .mark); XCTAssertNil(store.cardActions["night"])
        XCTAssertFalse(secondRan)
        let duplicate = await store.perform(cardID: "again") { XCTFail("Duplicate tap ran") }
        XCTAssertFalse(duplicate)
        gate?.resume()
        let firstOK = await first.value, secondOK = await second.value
        XCTAssertTrue(firstOK); XCTAssertTrue(secondOK); XCTAssertTrue(secondRan)
        XCTAssertFalse(store.busy); XCTAssertTrue(store.cardActions.isEmpty)
    }
    func testSignOutDiscardsQueuedCardWorkBeforeItCanRunInAnotherSession() async throws {
        StubProtocol.state.reset { _ in .init("{}") }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        var gate: CheckedContinuation<Void, Never>?
        var secondRan = false
        let first = Task { await store.perform(cardID: "again") { await withCheckedContinuation { gate = $0 } } }
        guard await waitForRegressionCondition({ gate != nil }) else { first.cancel(); XCTFail("First mutation did not start"); return }
        let second = Task { await store.perform(cardID: "frieren") { secondRan = true } }
        guard await waitForRegressionCondition({ store.cardActions["frieren"] != nil }) else { gate?.resume(); _ = await first.value; second.cancel(); XCTFail("Second mutation did not queue"); return }
        store.signOut(); gate?.resume()
        let firstOK = await first.value, secondOK = await second.value
        XCTAssertFalse(firstOK); XCTAssertFalse(secondOK); XCTAssertFalse(secondRan)
        XCTAssertTrue(store.cardActions.isEmpty); XCTAssertTrue(StubProtocol.state.recorded().isEmpty)
    }
    func testConfirmedWriteRefreshFailurePreventsQueuedCardFromWritingAgainstStaleData() async throws {
        StubProtocol.state.reset { _ in .init(503, #"{"error":{"message":"Synthetic refresh outage"}}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        var gate: CheckedContinuation<Void, Never>?
        var secondRan = false
        let first = Task { await store.perform(cardID: "again") { await withCheckedContinuation { gate = $0 } } }
        guard await waitForRegressionCondition({ gate != nil }) else { first.cancel(); XCTFail("First mutation did not start"); return }
        let second = Task { await store.perform(cardID: "frieren") { secondRan = true } }
        guard await waitForRegressionCondition({ store.cardActions["frieren"] != nil }) else { gate?.resume(); _ = await first.value; second.cancel(); XCTFail("Second mutation did not queue"); return }
        gate?.resume()
        let firstOK = await first.value, secondOK = await second.value
        XCTAssertTrue(firstOK); XCTAssertFalse(secondOK); XCTAssertFalse(secondRan)
        XCTAssertTrue(store.needsMutationRefresh); XCTAssertTrue(store.cardActions.isEmpty)
    }
    func testIdenticalUndoLabelsHaveDistinctLifetimes() {
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage))
        store.undoLabel = "Watch marked"; let first = store.undoNoticeID
        store.undoLabel = "Watch marked"
        XCTAssertNotEqual(store.undoNoticeID, first)
        store.dismissUndo(); XCTAssertNil(store.undoLabel)
    }
    func testGlanceCompletionOnlyWritesTheSelectedSeasonAndRetainsUndoReceipts() async throws {
        let workspace = PreviewData.upcomingWorkspace
        let pages = try workspacePages(workspace)
        StubProtocol.state.reset { request in
            if request.url?.path.hasSuffix("/watches") == true {
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
                let id = body["episodeId"] as? String ?? "missing"
                let event: [String: Any] = ["id": "new-" + id, "operationId": body["operationId"] ?? "missing", "titleId": "again", "episodeId": id, "watchedAt": "2026-10-23T12:00:00Z", "recordedAt": "2026-10-23T12:00:00Z", "origin": "manual", "version": 1]
                return .init(String(decoding: try! JSONSerialization.data(withJSONObject: ["event": event, "added": true]), as: UTF8.self))
            }
            return .init(pages[request.url?.query ?? ""] ?? "{}")
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = workspace
        let result = await store.completeCardSeason("again", season: 1)
        XCTAssertTrue(result); XCTAssertEqual(store.undoLabel, "Season progress updated")
        let recorded = try StubProtocol.state.recorded().filter { $0.url?.path.hasSuffix("/watches") == true }.map(bodyObject)
        let expected = Set(workspace.episodes.filter { $0.titleId == "again" && $0.season == 1 && $0.number > 8 }.map(\.id))
        XCTAssertEqual(Set(recorded.compactMap { $0["episodeId"] as? String }), expected)
        XCTAssertFalse(recorded.isEmpty)
        XCTAssertFalse(StubProtocol.state.recorded().contains { $0.url?.path == "/api/titles/bulk" })
        XCTAssertEqual(store.workspace.episodes.filter { $0.titleId == "again" && $0.season == 2 }.count, 3)
    }
    func testAnOffscreenCardCanCacheItsValidReadWithoutPublishingIntoTheCancelledView() async throws {
        let gate = StubProtocol.ResponseGate()
        StubProtocol.state.reset { _ in
            var response = StubProtocol.Reply(#"{"progress":{"watched":8,"total":16},"next":null,"previous":null}"#)
            response.gate = gate; return response
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace
        let title = try XCTUnwrap(store.title("again"))
        let disappearing = Task { () -> Bool in
            do { _ = try await store.card(title); return true }
            catch is CancellationError { return false }
            catch { XCTFail("Unexpected card error: \(error)"); return false }
        }
        guard await waitForRegressionCondition({ !StubProtocol.state.recorded().isEmpty }) else { disappearing.cancel(); gate.release(); XCTFail("Card read never started"); return }
        disappearing.cancel(); gate.release()
        let published = await disappearing.value
        XCTAssertFalse(published); XCTAssertNotNil(store.cachedCard(title))
        let retained = try await store.card(title)
        XCTAssertEqual(retained.progress.watched, 8)
        XCTAssertEqual(StubProtocol.state.recorded().count, 1)
    }
    func testPublicRatingAuthenticationFailureRequiresSignInWithoutCachingProviderFailure() async throws {
        for status in [401, 403, 302] {
            StubProtocol.state.reset { _ in .init(status, "Private sign-in", contentType: "text/html") }
            let storage = MemorySessionStorage(); storage.credential = credential
            let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace
            await store.communityRatings.prepare(["older-score"]) { _ in ["older-score": PublicRating(score: 8.0, state: "rated")] }
            await store.loadPublicRatings([try XCTUnwrap(store.workspace.titles.first)], source: .trakt)
            XCTAssertTrue(store.needsSignIn)
            XCTAssertEqual(store.error, APIError.signIn.localizedDescription)
            XCTAssertTrue(store.communityRatings.entries.isEmpty)
            XCTAssertFalse(store.communityRatings.unavailable); XCTAssertFalse(store.communityRatings.loading)
            XCTAssertEqual(StubProtocol.state.recorded().count, 1)
        }
    }
    func testPublicRatingProviderFailureDoesNotExpireThePrivateSession() async throws {
        StubProtocol.state.reset { _ in .init(503, "Provider unavailable", contentType: "text/plain") }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace
        let title = try XCTUnwrap(store.workspace.titles.first)
        await store.loadPublicRatings([title], source: .trakt)
        XCTAssertFalse(store.needsSignIn); XCTAssertNil(store.error)
        XCTAssertEqual(store.communityRatings.entries[title.id]?.state, "unavailable")
        XCTAssertFalse(store.communityRatings.loading)
    }
    func testOldRatingAuthenticationFailureCannotExpireANewerSignedInSession() async throws {
        let gate = StubProtocol.ResponseGate()
        StubProtocol.state.reset { request in
            if request.url?.path == "/api/library/ratings" {
                var reply = StubProtocol.Reply(403, "Expired", contentType: "text/html"); reply.gate = gate; return reply
            }
            if request.url?.path == "/api/session" { return .init(#"{"authenticated":true}"#) }
            return .init(#"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = PreviewData.workspace
        let title = try XCTUnwrap(store.workspace.titles.first)
        let old = Task { await store.loadPublicRatings([title], source: .trakt) }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().contains { $0.url?.path == "/api/library/ratings" } }) else {
            old.cancel(); gate.release(); XCTFail("Ratings request did not start"); return
        }
        store.signOut()
        await store.connect(AccessCredential(token: "synthetic-new-session", expires: .distantFuture))
        XCTAssertFalse(store.needsSignIn); XCTAssertTrue(store.hasLoadedWorkspace)
        gate.release(); await old.value
        XCTAssertFalse(store.needsSignIn); XCTAssertNil(store.error)
        XCTAssertTrue(store.communityRatings.entries.isEmpty); XCTAssertFalse(store.communityRatings.loading)
        XCTAssertEqual(storage.credential?.token, "synthetic-new-session")
    }
    func testDuplicateSectionsNeverReplaceOrCacheThePreviousCompleteDiary() async throws {
        let original = PreviewData.workspace
        for section in ["titles", "episodes", "events", "locations"] {
            var malformed = original
            switch section {
            case "titles": malformed.titles.append(try XCTUnwrap(original.titles.first))
            case "episodes": malformed.episodes.append(try XCTUnwrap(original.episodes.first))
            case "events": malformed.events.append(try XCTUnwrap(original.events.first))
            default: malformed.locations.append(try XCTUnwrap(original.locations.first))
            }
            let pages = try workspacePages(malformed)
            StubProtocol.state.reset { request in .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#) }
            let storage = MemorySessionStorage(); storage.credential = credential
            let cache = MemoryWorkspaceCache()
            try cache.save(original, scope: credential.cacheScope, at: .now)
            let store = DiaryStore(api: api(storage), cache: cache)
            await store.refresh()
            XCTAssertNotNil(store.error, "Duplicate \(section) must be rejected")
            XCTAssertEqual(store.workspace.titles, original.titles); XCTAssertEqual(store.workspace.episodes, original.episodes)
            XCTAssertEqual(store.workspace.events, original.events); XCTAssertEqual(store.workspace.locations, original.locations)
            XCTAssertEqual(cache.load(scope: credential.cacheScope)?.workspace.events, original.events)
            XCTAssertTrue(store.showingCachedSnapshot); XCTAssertFalse(store.loading)
        }
    }
    func testOverlappingPagesAreRejectedInsteadOfPublishingConflictingTitleIdentities() async throws {
        let original = PreviewData.workspace
        let first = try XCTUnwrap(original.titles.first)
        var conflicting = first; conflicting.name = "Conflicting duplicate"
        func page(_ title: MediaTitle, next: String?) throws -> String {
            let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([title]))
            return String(decoding: try JSONSerialization.data(withJSONObject: ["items": rows, "next": next as Any? ?? NSNull()]), as: UTF8.self)
        }
        let initial = try page(first, next: "synthetic-next"), overlap = try page(conflicting, next: nil)
        StubProtocol.state.reset { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            guard query.first(where: { $0.name == "section" })?.value == "titles" else { return .init(#"{"items":[],"next":null}"#) }
            return .init(query.contains(where: { $0.name == "after" }) ? overlap : initial)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let store = DiaryStore(api: api(storage)); store.workspace = original; store.hasLoadedWorkspace = true
        await store.refresh()
        XCTAssertEqual(store.error, WorkspaceIntegrityError.duplicateIdentity(section: "titles").localizedDescription)
        XCTAssertEqual(store.workspace.titles, original.titles)
        XCTAssertEqual(store.workspace.events, original.events)
        XCTAssertEqual(StubProtocol.state.recorded().filter { $0.url?.query?.contains("section=titles") == true }.count, 2)
    }
    func testCrossSectionImportRaceRetriesReadOnceBeforePublishingAndCaching() async throws {
        let original = PreviewData.workspace
        let owner = try XCTUnwrap(original.events.first?.titleId)
        var raced = original; raced.titles.removeAll { $0.id == owner }
        let invalid = try workspacePages(raced), valid = try workspacePages(original)
        StubProtocol.state.reset { request in
            let query = request.url?.query ?? ""
            let titleReads = StubProtocol.state.recorded().filter { $0.url?.query == "section=titles" }.count
            return .init((query == "section=titles" && titleReads == 1 ? invalid : valid)[query] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let cache = MemoryWorkspaceCache(); try cache.save(original, scope: credential.cacheScope, at: .now)
        let store = DiaryStore(api: api(storage), cache: cache)
        await store.refresh()
        XCTAssertNil(store.error); XCTAssertEqual(StubProtocol.state.recorded().count, 8)
        XCTAssertEqual(store.workspace.titles, original.titles); XCTAssertEqual(store.workspace.events, original.events)
        XCTAssertEqual(cache.load(scope: credential.cacheScope)?.workspace.titles, original.titles)
        XCTAssertFalse(store.showingCachedSnapshot)
    }
    func testPersistentCrossSectionInconsistencyStopsAfterTwoReadsAndPreservesCache() async throws {
        let original = PreviewData.workspace
        let owner = try XCTUnwrap(original.events.first?.titleId)
        var raced = original; raced.titles.removeAll { $0.id == owner }
        let pages = try workspacePages(raced)
        StubProtocol.state.reset { request in .init(pages[request.url?.query ?? ""] ?? #"{"items":[],"next":null}"#) }
        let storage = MemorySessionStorage(); storage.credential = credential
        let cache = MemoryWorkspaceCache(); try cache.save(original, scope: credential.cacheScope, at: .now)
        let store = DiaryStore(api: api(storage), cache: cache)
        await store.refresh()
        XCTAssertEqual(store.error, WorkspaceIntegrityError.incompleteSnapshot.localizedDescription)
        XCTAssertEqual(StubProtocol.state.recorded().count, 8)
        XCTAssertEqual(store.workspace.titles, original.titles); XCTAssertEqual(store.workspace.events, original.events)
        XCTAssertEqual(cache.load(scope: credential.cacheScope)?.workspace.events, original.events)
        XCTAssertTrue(store.showingCachedSnapshot)
    }
    func testCrossSectionReadRetryHonorsQuotaRatherThanLoopingOrReplacingTheDiary() async throws {
        let original = PreviewData.workspace
        let owner = try XCTUnwrap(original.events.first?.titleId)
        var raced = original; raced.titles.removeAll { $0.id == owner }
        let pages = try workspacePages(raced)
        StubProtocol.state.reset { request in
            let query = request.url?.query ?? ""
            if query == "section=titles", StubProtocol.state.recorded().filter({ $0.url?.query == query }).count == 2 {
                return .init(503, #"{"error":{"code":"database_read_limit","message":"Quota","resetAt":"2999-01-01T00:00:00Z"}}"#)
            }
            return .init(pages[query] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let cache = MemoryWorkspaceCache(); try cache.save(original, scope: credential.cacheScope, at: .now)
        let store = DiaryStore(api: api(storage), cache: cache)
        await store.refresh()
        XCTAssertNotNil(store.quotaBlockedUntil); XCTAssertNotNil(store.error)
        XCTAssertLessThanOrEqual(StubProtocol.state.recorded().count, 8)
        XCTAssertEqual(store.workspace.titles, original.titles); XCTAssertEqual(store.workspace.events, original.events)
        XCTAssertEqual(cache.load(scope: credential.cacheScope)?.workspace.events, original.events)
    }
    func testSignOutDuringTheConsistencyRetryCannotPublishOrRecreateTheOldCache() async throws {
        let original = PreviewData.workspace
        let owner = try XCTUnwrap(original.events.first?.titleId)
        var raced = original; raced.titles.removeAll { $0.id == owner }
        let invalid = try workspacePages(raced), valid = try workspacePages(original)
        let gate = StubProtocol.ResponseGate()
        let validTitlePage = try XCTUnwrap(valid["section=titles"])
        StubProtocol.state.reset { request in
            let query = request.url?.query ?? ""
            let titleReads = StubProtocol.state.recorded().filter { $0.url?.query == "section=titles" }.count
            if query == "section=titles", titleReads == 2 {
                var reply = StubProtocol.Reply(validTitlePage); reply.gate = gate; return reply
            }
            return .init((query == "section=titles" && titleReads == 1 ? invalid : valid)[query] ?? #"{"items":[],"next":null}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        let cache = MemoryWorkspaceCache(); try cache.save(original, scope: credential.cacheScope, at: .now)
        let store = DiaryStore(api: api(storage), cache: cache)
        let task = Task { await store.refresh() }
        guard await waitForRegressionCondition({ StubProtocol.state.recorded().filter { $0.url?.query == "section=titles" }.count == 2 }) else {
            gate.release(); await task.value; XCTFail("No consistency retry"); return
        }
        store.signOut(); gate.release(); await task.value
        XCTAssertTrue(store.needsSignIn); XCTAssertFalse(store.hasLoadedWorkspace)
        XCTAssertTrue(store.workspace.titles.isEmpty); XCTAssertTrue(store.workspace.events.isEmpty)
        XCTAssertNil(cache.load(scope: credential.cacheScope))
    }
    private func workspacePages(_ workspace: Workspace) throws -> [String: String] {
        let sections: [String: Any] = ["titles": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.titles)),
                                       "episodes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.episodes)),
                                       "events": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.events)),
                                       "locations": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.locations))]
        return try Dictionary(uniqueKeysWithValues: sections.map { key, value in
            ("section=" + key, String(decoding: try JSONSerialization.data(withJSONObject: ["items": value, "next": NSNull()]), as: UTF8.self))
        })
    }
    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; data.append(contentsOf: buffer.prefix(size)) }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
