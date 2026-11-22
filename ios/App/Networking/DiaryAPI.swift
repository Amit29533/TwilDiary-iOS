import Foundation
import Observation
import Security
import TwilDiaryCore

enum AppConfiguration {
    static let backend = BackendEndpoint.production
    /// A Cloudflare Access service token for your server (Zero Trust → Access → Service auth), built
    /// in when the build sets one. It only gets the app's requests past Access, without its browser
    /// sign-in; your server still checks the diary sign-in itself. Revoke it in Cloudflare any time.
    struct AccessServiceToken: Sendable { let id: String; let secret: String }
    static let accessServiceToken: AccessServiceToken? = {
        func value(_ key: String) -> String? {
            guard let text = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.hasPrefix("$(") else { return nil }
            return text
        }
        guard let id = value("TwilDiaryAccessClientID"), let secret = value("TwilDiaryAccessClientSecret") else { return nil }
        return AccessServiceToken(id: id, secret: secret)
    }()
    /// Adds the service token's headers to a request for your server (nothing when there's none).
    static func passAccess(_ request: inout URLRequest) {
        guard let token = accessServiceToken else { return }
        request.setValue(token.id, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(token.secret, forHTTPHeaderField: "CF-Access-Client-Secret")
    }
    /// A sign-in Cloudflare Access issued (its JWT comes from `<team>.cloudflareaccess.com`), as
    /// opposed to one your server issued after a Trakt, passcode or token sign-in.
    static func isAccessSignIn(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = claims["iss"] as? String else { return false }
        return issuer.contains("cloudflareaccess.com")
    }
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
    case signIn, notModified, message(String), transport(String), rejected(Int, String), databaseLimit(Date?)
    var errorDescription: String? {
        switch self {
        case .signIn: "Your private session expired. Sign in again to continue."
        case .notModified: "Your diary has not changed."
        case .message(let text), .transport(let text): text
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

final class StopRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward a private credential to an authentication or third-party redirect.
        completionHandler(nil)
    }
}

struct EmptyResponse: Decodable {}
