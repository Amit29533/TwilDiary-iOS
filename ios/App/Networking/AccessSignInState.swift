import Foundation
import Observation

/// Candidate cookies are still validated by DiaryAPI.authenticate before Keychain.
enum AccessCookiePolicy {
    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16_384
            && token.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 && ![34, 44, 59, 92].contains($0.value) }
    }
    static func trusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == AppConfiguration.backend.host?.lowercased()
            && url.port == nil && url.user == nil && url.password == nil
    }
    static func isSessionFinish(_ url: URL?) -> Bool { trusted(url) && url?.path == "/api/session" }
    static func credential(_ cookies: [HTTPCookie], at url: URL?, now: Date = .now) -> AccessCredential? {
        guard trusted(url), let host = AppConfiguration.backend.host else { return nil }
        let cookie = cookies.first { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let token = cookie.value, path = cookie.path
            let matchesAPI = path == "/" || path == "/api" || path == "/api/" || path == "/api/session"
            return cookie.name == "CF_Authorization" && cookie.isSecure && domain == host && matchesAPI
                && (cookie.expiresDate.map { $0 > now } ?? true) && validToken(token)
        }
        return cookie.map { AccessCredential(token: $0.value, expires: $0.expiresDate) }
    }
}

/// Distinct browser tickets reject old callbacks after teardown or Retry.
@MainActor @Observable final class AccessSignInState {
    private(set) var error: String?
    @ObservationIgnored private var ticket: UUID?
    @ObservationIgnored private var completed = false
    func begin() -> UUID { let next = UUID(); ticket = next; completed = false; return next }
    func active(_ candidate: UUID) -> Bool { ticket == candidate && !completed }
    func stop(_ candidate: UUID) { if ticket == candidate { ticket = nil } }
    func restart() { ticket = nil; completed = false; error = nil }
    func started(_ candidate: UUID) { if active(candidate) { error = nil } }
    func failed(_ failure: Error, ticket candidate: UUID) {
        let value = failure as NSError
        guard active(candidate), !(value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled) else { return }
        error = "The sign-in page couldn’t load. Check your connection and try again."
    }
    func interrupted(_ candidate: UUID) { if active(candidate) { error = "Sign-in was interrupted. Please try again." } }
    func missingCredential(_ candidate: UUID) { if active(candidate) { error = "Sign-in finished without a usable diary session. Please try again." } }
    func consume(_ cookies: [HTTPCookie], at url: URL?, ticket candidate: UUID, now: Date = .now) -> AccessCredential? {
        guard active(candidate), let value = AccessCookiePolicy.credential(cookies, at: url, now: now) else { return nil }
        completed = true; error = nil
        return value
    }
}
