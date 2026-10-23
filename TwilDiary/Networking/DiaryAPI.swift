import Foundation
import Security
import TwilDiaryCore

enum AppConfiguration {
    // No credentials are compiled into the app or supplied to CI.
    static let backend = URL(string: "https://twildiary-v2.amit29533.workers.dev")!
}

struct AccessCredential: Codable {
    let token: String
    let expires: Date?
    var isValid: Bool { expires.map { $0 > .now } ?? true }
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
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIError.message("Could not save your private session securely.") }
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw APIError.message("Could not save your private session securely.") }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

enum APIError: LocalizedError {
    case signIn, message(String), rejected(Int, String), databaseLimit(Date?)
    var errorDescription: String? {
        switch self {
        case .signIn: "Your private session expired. Sign in again to continue."
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

@MainActor final class DiaryAPI {
    var credential: AccessCredential?
    private let session: URLSession
    private let storage: any SessionStoring
    init(configuration: URLSessionConfiguration = .ephemeral, storage: any SessionStoring = KeychainSessionStorage()) {
        self.storage = storage
        let config = configuration
        config.httpCookieAcceptPolicy = .never; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: StopRedirects(), delegateQueue: nil)
        credential = storage.read()
    }
    func authenticate(_ value: AccessCredential) async throws {
        let previous = credential
        credential = value
        do {
            let session: SessionResponse = try await request("/api/session")
            guard session.authenticated else { throw APIError.signIn }
            try storage.save(value)
        } catch {
            credential = previous
            throw error
        }
    }
    func signOut() {
        storage.delete()
        credential = nil
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard path.hasPrefix("/api/"), let url = URL(string: path, relativeTo: AppConfiguration.backend)?.absoluteURL,
              url.host == AppConfiguration.backend.host, url.scheme == "https" else { throw APIError.message("Invalid diary request.") }
        guard let credential, credential.isValid else { throw APIError.signIn }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CF_Authorization=\(credential.token)", forHTTPHeaderField: "Cookie")
        if method != "GET" {
            request.setValue(AppConfiguration.backend.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.message("No response from the diary.") }
        guard http.statusCode != 401 && http.statusCode != 403 && !(300..<400).contains(http.statusCode) else { throw APIError.signIn }
        let isJSON = http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true
        if !(200..<300).contains(http.statusCode) {
            let envelope = isJSON ? (try? JSONDecoder().decode(ErrorEnvelope.self, from: data)) : nil
            if ["database_read_limit", "database_write_limit"].contains(envelope?.error.code ?? "") {
                let reset = envelope?.error.resetAt.flatMap { ISO8601DateFormatter().date(from: $0) ?? ISO8601DateFormatter.fractional.date(from: $0) }
                throw APIError.databaseLimit(reset)
            }
            throw APIError.rejected(http.statusCode, envelope?.error.message ?? "The change was not confirmed. Refresh before trying again.")
        }
        guard isJSON else { throw APIError.message("The diary returned an unexpected response. Please try again.") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func allPages<T: Decodable & Sendable>(_ section: String, as: T.Type) async throws -> [T] {
        var result: [T] = []; var after: String?; var visited = Set<String>()
        repeat {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "section", value: section)]
            if let after { query.queryItems?.append(URLQueryItem(name: "after", value: after)) }
            let page: WorkspacePage<T> = try await request("/api/workspace?" + (query.percentEncodedQuery ?? ""))
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
