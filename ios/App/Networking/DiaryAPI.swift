import Foundation
import Observation
import Security
import TwilDiaryCore

enum AppConfiguration {
    // No credentials are compiled into the app or supplied to CI.
    static let backend = BackendEndpoint.production
}

struct AccessCredential: Codable {
    let token: String
    let expires: Date?
    var isValid: Bool { !token.isEmpty && (expires.map { $0 > .now } ?? true) }
}

@MainActor protocol SessionStoring {
    func read() -> AccessCredential?
    func save(_ credential: AccessCredential) throws
    func delete()
}

@MainActor struct KeychainSessionStorage: SessionStoring {
    func read() -> AccessCredential? { SessionKeychain.read() }
    func save(_ credential: AccessCredential) throws { try SessionKeychain.save(credential) }
    func delete() { SessionKeychain.delete() }
}

@MainActor enum SessionKeychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.amit29533.TwilDiary.access",
        kSecAttrAccount as String: "hosted-diary"
    ]
    static func read() -> AccessCredential? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder().decode(AccessCredential.self, from: data), credential.isValid else { return nil }
        return credential
    }
    static func save(_ value: AccessCredential) throws {
        let data = try JSONEncoder().encode(value)
        let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIError.message("Could not save your private session securely.") }
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw APIError.message("Could not save your private session securely.") }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

enum APIError: LocalizedError {
    case signIn, notModified, message(String), rejected(Int, String), databaseLimit(Date?)
    var errorDescription: String? {
        switch self {
        case .signIn: "Your private session expired. Sign in again to continue."
        case .notModified: "Your diary has not changed."
        case .message(let text): text
        case .rejected(_, let text): text
        case .databaseLimit(let reset):
            if let reset {
                "Cloudflare’s daily database limit has been reached. Your data is safe. Try again after \(reset.formatted(date: .abbreviated, time: .shortened))."
            } else {
                "Cloudflare’s daily database limit has been reached. Your data is safe. Try again after midnight UTC."
            }
        }
    }
}

private final class StopRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward the private cookie to an authentication or third-party redirect.
        completionHandler(nil)
    }
}

@MainActor @Observable final class DiaryAPI {
    var credential: AccessCredential?
    private let session: URLSession
    private let boundedReadSession: URLSession
    private let storage: any SessionStoring
    private let clock: @MainActor () -> Date
    @ObservationIgnored private var quotaGeneration = UUID()
    @ObservationIgnored private var quotaRevision = UUID()
    private(set) var quotaBlockedUntil: Date?
    var isQuotaBlocked: Bool { quotaBlockedUntil.map { $0 > clock() } ?? false }
    func retryQuota() { quotaGeneration = UUID(); quotaBlockedUntil = nil }
    @ObservationIgnored private var sessionGeneration = UUID()
    init(configuration: URLSessionConfiguration = .ephemeral, storage: any SessionStoring = KeychainSessionStorage(), clock: @escaping @MainActor () -> Date = { .now }) {
        self.storage = storage
        self.clock = clock
        let config = configuration
        config.httpCookieAcceptPolicy = .never; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: StopRedirects(), delegateQueue: nil)
        let bounded = config.copy() as! URLSessionConfiguration
        bounded.timeoutIntervalForRequest = 8
        bounded.timeoutIntervalForResource = 10
        boundedReadSession = URLSession(configuration: bounded, delegate: StopRedirects(), delegateQueue: nil)
        credential = storage.read()
    }
    func authenticate(_ value: AccessCredential) async throws {
        let generation = UUID(); sessionGeneration = generation
        let previous = credential
        credential = value
        do {
            let session: SessionResponse = try await request("/api/session")
            guard generation == sessionGeneration else { throw CancellationError() }
            guard session.authenticated else { throw APIError.signIn }
            try storage.save(value)
            retryQuota()
        } catch {
            if generation == sessionGeneration { credential = previous }
            throw error
        }
    }
    func signOut() {
        sessionGeneration = UUID()
        retryQuota()
        storage.delete()
        credential = nil
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> T {
        let data = try await responseData(path, method: method, body: body, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func responseData(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        let generation = sessionGeneration
        let quotaTicket = quotaGeneration
        let quotaVersion = quotaRevision
        guard path.hasPrefix("/api/"), let url = URL(string: path, relativeTo: AppConfiguration.backend)?.absoluteURL,
              BackendEndpoint.isPrivateAPI(url) else { throw APIError.message("Invalid diary request.") }
        guard let credential, credential.isValid else { throw APIError.signIn }
        // Session validation is independent of D1. Preserve explicit writes and
        // cached reads, but stop new automatic GET traffic during a known quota.
        if method == "GET", path != "/api/session", isQuotaBlocked { throw APIError.databaseLimit(quotaBlockedUntil) }
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CF_Authorization=\(credential.token)", forHTTPHeaderField: "Cookie")
        if method != "GET" {
            request.setValue(AppConfiguration.backend.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        }
        let (data, response) = try await send(request, session: timeout == nil ? session : boundedReadSession, generation: generation, quotaTicket: quotaTicket)
        guard generation == sessionGeneration else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw APIError.message("No response from the diary.") }
        let isJSON = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true
        if http.statusCode == 304 { throw APIError.notModified }
        if http.statusCode == 401 || (300..<400).contains(http.statusCode) || (http.statusCode == 403 && !isJSON) { throw APIError.signIn }
        if !(200..<300).contains(http.statusCode) {
            let envelope = isJSON ? (try? JSONDecoder().decode(ErrorEnvelope.self, from: data)) : nil
            if ["database_read_limit", "database_write_limit"].contains(envelope?.error.code ?? "") {
                let reset = envelope?.error.resetAt.flatMap { ISO8601DateFormatter().date(from: $0) ?? ISO8601DateFormatter.fractional.date(from: $0) }
                var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
                let fallback = utc.nextDate(after: clock(), matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? clock().addingTimeInterval(86_400)
                guard quotaTicket == quotaGeneration else { throw CancellationError() }
                // A quota response must not cancel its sibling workspace reads:
                // async-let can otherwise surface a sibling CancellationError
                // before the original limit, leaving the screen without an error.
                // Only an explicit retry/session change invalidates the request
                // generation. A separate revision fences older successful reads.
                quotaRevision = UUID()
                let nextReset = reset.flatMap { $0 > clock() ? $0 : nil } ?? fallback
                quotaBlockedUntil = max(quotaBlockedUntil ?? nextReset, nextReset)
                throw APIError.databaseLimit(quotaBlockedUntil)
            }
            let fallback = method == "GET"
                ? "The diary could not be loaded. Please try refreshing."
                : "The change was not confirmed. Refresh before trying again."
            if path.hasPrefix("/api/trakt/sync") || url.path == "/api/trakt/status" {
                throw TraktTransferFailure(status: http.statusCode, code: envelope?.error.code ?? "unconfirmed_response",
                    message: envelope?.error.message ?? fallback,
                    retryAt: TraktTransferFailure.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: clock()))
            }
            throw APIError.rejected(http.statusCode, envelope?.error.message ?? fallback)
        }
        guard isJSON else { throw APIError.message("The diary returned an unexpected response. Please try again.") }
        if quotaTicket == quotaGeneration, quotaVersion == quotaRevision,
           path.hasPrefix("/api/workspace") || path.hasPrefix("/api/glance/") { quotaBlockedUntil = nil }
        return data
    }
    private func send(_ request: URLRequest, session: URLSession, generation: UUID, quotaTicket: UUID) async throws -> (Data, URLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            guard generation == sessionGeneration, quotaTicket == quotaGeneration else { throw CancellationError() }
            do { return try await session.data(for: request) }
            catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                // A dropped GET is safe to repeat once. Writes retain their
                // receipt/operation identity and are never retried here. A full
                // timeout is surfaced immediately rather than doubled to60s.
                if request.httpMethod == "GET", attempt == 0, error.code == .networkConnectionLost {
                    try await Task.sleep(for: .milliseconds(350)); continue
                }
                let message: String
                switch error.code {
                case .notConnectedToInternet, .dataNotAllowed: message = "You’re offline. Connect to refresh your diary or make changes."
                case .timedOut: message = request.httpMethod == "GET" ? "The diary took too long to answer. Try again." : "The request timed out before the change was confirmed. Refresh before retrying."
                case .networkConnectionLost: message = request.httpMethod == "GET" ? "The connection dropped. Try refreshing." : "The connection dropped. The change was not confirmed. Refresh before retrying."
                default: message = request.httpMethod == "GET" ? "The diary could not be reached. Check your connection and try again." : "The change could not be confirmed. Check your connection and refresh before retrying."
                }
                if request.url?.path.hasPrefix("/api/trakt/sync") == true || request.url?.path == "/api/trakt/status" {
                    throw TraktTransferFailure(status: 0, code: "network_unavailable", message: message)
                }
                throw APIError.message(message)
            }
        }
        throw APIError.message("The diary could not be reached. Please try again.")
    }
    func allPages<T: Decodable & Sendable>(_ section: String, as: T.Type) async throws -> [T] {
        let generation = sessionGeneration
        var result: [T] = []; var after: String?; var visited = Set<String>()
        repeat {
            try Task.checkCancellation()
            guard generation == sessionGeneration else { throw CancellationError() }
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "section", value: section)]
            if let after { query.queryItems?.append(URLQueryItem(name: "after", value: after)) }
            let data = try await responseData("/api/workspace?" + (query.percentEncodedQuery ?? ""))
            let decoding = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let page = try JSONDecoder().decode(WorkspacePage<T>.self, from: data)
                try Task.checkCancellation()
                return page
            }
            let page = try await withTaskCancellationHandler(operation: { try await decoding.value }, onCancel: { decoding.cancel() })
            try Task.checkCancellation()
            guard generation == sessionGeneration else { throw CancellationError() }
            result.append(contentsOf: page.items); after = page.next
            if let after, !visited.insert(after).inserted { throw APIError.message("The diary returned a repeated page. Please refresh.") }
        } while after != nil
        return result
    }
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: String?; let message: String; let resetAt: String? }
        let error: Detail
    }
    private struct SessionResponse: Decodable { let authenticated: Bool }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct EmptyResponse: Decodable {}
