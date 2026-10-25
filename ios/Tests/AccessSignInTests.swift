import XCTest
@testable import TwilDiary

@MainActor final class AccessSignInTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var session: URL { AppConfiguration.backend.appendingPathComponent("api/session") }
    private func cookie(name: String = "CF_Authorization", domain: String? = nil, path: String = "/", token: String = "synthetic.header.signature", secure: Bool = true, expires: Date? = nil) throws -> HTTPCookie {
        var fields: [HTTPCookiePropertyKey: Any] = [.name: name, .value: token, .domain: domain ?? AppConfiguration.backend.host ?? "", .path: path]
        if secure { fields[.secure] = "TRUE" }
        if let expires { fields[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: fields))
    }
    func testOnlyTheProtectedHTTPSOriginCanSupplyACandidateSession() throws {
        let value = try cookie()
        XCTAssertNotNil(AccessCookiePolicy.credential([value], at: session, now: now))
        XCTAssertNotNil(AccessCookiePolicy.credential([value], at: AppConfiguration.backend.appendingPathComponent("preview"), now: now))
        for text in ["http://twildiary-v2.amit29533.workers.dev/api/session", "https://other.workers.dev/api/session", "https://team.cloudflareaccess.com/api/session", "https://twildiary-v2.amit29533.workers.dev:8443/api/session", "https://user@twildiary-v2.amit29533.workers.dev/api/session"] {
            XCTAssertNil(AccessCookiePolicy.credential([value], at: URL(string: text), now: now))
        }
        XCTAssertNil(AccessCookiePolicy.credential([value], at: nil, now: now))
    }
    func testProviderParentUnrelatedInsecureExpiredAndWrongPathCookiesAreRejected() throws {
        let candidates = try [cookie(domain: "team.cloudflareaccess.com"), cookie(domain: "workers.dev"), cookie(domain: "other.workers.dev"), cookie(path: "/preview"), cookie(name: "another-cookie"), cookie(secure: false), cookie(expires: now.addingTimeInterval(-60))]
        for value in candidates { XCTAssertNil(AccessCookiePolicy.credential([value], at: session, now: now)) }
        XCTAssertNotNil(AccessCookiePolicy.credential([try cookie(path: "/api", expires: now.addingTimeInterval(600))], at: session, now: now))
        XCTAssertNotNil(AccessCookiePolicy.credential([try cookie(domain: "." + (AppConfiguration.backend.host ?? ""))], at: session, now: now))
    }
    func testOversizedCookieCannotBecomeARequestHeader() {
        // Foundation refuses some malformed cookies before policy evaluation.
        // Exercise the same production header validator without constructing one.
        XCTAssertTrue(AccessCookiePolicy.validToken(String(repeating: "a", count: 16_384)))
        XCTAssertFalse(AccessCookiePolicy.validToken(String(repeating: "a", count: 16_385)))
        for token in ["", "a b", "a\nb", "a;b", "a,b", "a\"b", "a\\b", "aéb"] {
            XCTAssertFalse(AccessCookiePolicy.validToken(token))
        }
    }
    func testOneAttemptConsumesACandidateOnlyOnce() throws {
        let state = AccessSignInState(), value = try cookie()
        let ticket = state.begin()
        XCTAssertEqual(state.consume([value], at: session, ticket: ticket, now: now)?.token, value.value)
        XCTAssertNil(state.consume([value], at: session, ticket: ticket, now: now))
        XCTAssertFalse(state.active(ticket)); XCTAssertNil(state.error)
    }
    func testDismissedAndReplacedBrowsersCannotCompleteFromLateCookies() throws {
        let state = AccessSignInState(), value = try cookie()
        let old = state.begin(); state.stop(old)
        XCTAssertNil(state.consume([value], at: session, ticket: old, now: now))
        let replacement = state.begin()
        state.stop(old)
        XCTAssertTrue(state.active(replacement))
        XCTAssertNil(state.consume([value], at: session, ticket: old, now: now))
        XCTAssertNotNil(state.consume([value], at: session, ticket: replacement, now: now))
    }
    func testRetryPreservesCurrentAttemptAgainstOldFailuresAndCallbacks() throws {
        let state = AccessSignInState(), old = state.begin()
        state.failed(URLError(.notConnectedToInternet), ticket: old)
        XCTAssertNotNil(state.error)
        state.restart(); let next = state.begin()
        state.failed(URLError(.cannotFindHost), ticket: old); state.missingCredential(old)
        XCTAssertNil(state.error)
        XCTAssertNil(state.consume([try cookie()], at: session, ticket: old, now: now))
        XCTAssertTrue(state.active(next))
    }
    func testCancelledNavigationDoesNotShowAnErrorButFailuresOfferRecovery() {
        let state = AccessSignInState(), ticket = state.begin()
        state.failed(URLError(.cancelled), ticket: ticket); XCTAssertNil(state.error)
        state.failed(URLError(.timedOut), ticket: ticket); XCTAssertNotNil(state.error)
        state.started(ticket); XCTAssertNil(state.error)
        state.interrupted(ticket); XCTAssertNotNil(state.error)
    }
    func testOnlyTheCompletedBackendSessionStartsTheMissingCookieWait() throws {
        XCTAssertTrue(AccessCookiePolicy.isSessionFinish(session))
        XCTAssertFalse(AccessCookiePolicy.isSessionFinish(URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login")))
        XCTAssertFalse(AccessCookiePolicy.isSessionFinish(AppConfiguration.backend.appendingPathComponent("cdn-cgi/access/login")))
        XCTAssertFalse(AccessCookiePolicy.isSessionFinish(AppConfiguration.backend.appendingPathComponent("preview")))
        let state = AccessSignInState(), ticket = state.begin()
        state.missingCredential(ticket); XCTAssertNotNil(state.error)
        XCTAssertTrue(state.active(ticket), "A late real cookie may still finish after the recoverable message")
        XCTAssertNotNil(state.consume([try cookie()], at: session, ticket: ticket, now: now))
        XCTAssertNil(state.error)
    }
}
