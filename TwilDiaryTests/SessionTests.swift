import XCTest
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
    struct Reply: Sendable {
        let status: Int
        let contentType: String
        let body: String
        init(_ body: String) { self.init(200, body) }
        init(_ status: Int, _ body: String, contentType: String = "application/json") {
            self.status = status; self.body = body; self.contentType = contentType
        }
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        private var handler: @Sendable (URLRequest) -> Reply = { _ in Reply(500, "{}") }
        private var requests: [URLRequest] = []
        func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
            lock.lock(); defer { lock.unlock() }
            self.handler = handler; requests = []
        }
        func reply(_ request: URLRequest) -> Reply {
            lock.lock(); requests.append(request); let handler = handler; lock.unlock()
            return handler(request)
        }
        func recorded() -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }; return requests
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class SessionTests: XCTestCase {
    private let credential = AccessCredential(token: "synthetic-test-session", expires: .distantFuture)
    private func api(_ storage: MemorySessionStorage) -> DiaryAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return DiaryAPI(configuration: configuration, storage: storage)
    }

    func testSignInSurvivesDatabaseQuotaAndDoesNotProbeWorkspaceForAuthentication() async {
        StubProtocol.state.reset { request in
            if request.url?.path == "/api/session" { return .init(#"{"authenticated":true}"#) }
            return .init(503, #"{"error":{"code":"database_read_limit","message":"Quota exhausted","resetAt":"2026-10-24T00:00:00.000Z"}}"#)
        }
        let storage = MemorySessionStorage(), api = api(storage)
        let store = DiaryStore(api: api)
        await store.connect(credential)
        XCTAssertFalse(store.needsSignIn)
        XCTAssertFalse(store.hasLoadedWorkspace)
        XCTAssertFalse(store.loading)
        XCTAssertEqual(storage.credential?.token, credential.token)
        XCTAssertEqual(api.credential?.token, credential.token)
        XCTAssertTrue(store.error?.contains("daily database limit") == true)
        let requests = StubProtocol.state.recorded()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/session", "/api/workspace"])
        XCTAssertEqual(requests.last?.url?.query, "section=titles")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=synthetic-test-session")
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

    func testWriteQuotaParsesResetWithoutSigningOut() async throws {
        StubProtocol.state.reset { _ in
            .init(503, #"{"error":{"code":"database_write_limit","message":"Quota exhausted","resetAt":"2026-10-24T00:00:00Z"}}"#)
        }
        let storage = MemorySessionStorage(); storage.credential = credential
        do {
            let _: EmptyResponse = try await api(storage).request("/api/workspace")
            XCTFail("Expected quota error")
        } catch APIError.databaseLimit(let reset) {
            XCTAssertEqual(reset, ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
        } catch { XCTFail("Unexpected error: \(error)") }
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
}
