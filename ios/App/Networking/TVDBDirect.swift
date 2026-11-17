import Foundation

@MainActor enum TVDBDirect {
    static var builtIn: String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "TwilDiaryTVDBKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    static func key(_ store: DiaryStore) -> String? {
        store.providerSettings.customTvdbKey ?? builtIn
    }

    /// Verify both the project key and read access to the Awards catalog.
    static func checkConnection(key: String) async throws {
        struct Login: Decodable {
            struct Credentials: Decodable { let token: String }
            let data: Credentials
        }
        struct Awards: Decodable {
            struct Award: Decodable { let id: Int }
            let data: [Award]
        }
        var login = URLRequest(url: URL(string: "https://api4.thetvdb.com/v4/login")!, timeoutInterval: 15)
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.setValue("application/json", forHTTPHeaderField: "Accept")
        login.httpBody = try JSONEncoder().encode(["apikey": key])
        let token = try await send(login, as: Login.self).data.token
        guard !token.isEmpty else { throw APIError.message("TheTVDB did not return an access token.") }

        var awards = URLRequest(url: URL(string: "https://api4.thetvdb.com/v4/awards")!, timeoutInterval: 15)
        awards.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        awards.setValue("application/json", forHTTPHeaderField: "Accept")
        let reply = try await send(awards, as: Awards.self)
        guard !reply.data.isEmpty else { throw APIError.message("TheTVDB returned an empty Awards catalog.") }
    }

    private static func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw APIError.message("TheTVDB didn’t answer.")
        }
        switch status {
        case 200..<300: break
        case 401, 403: throw APIError.message("TheTVDB didn’t accept these credentials. Check the API key.")
        case 429: throw APIError.message("TheTVDB is busy. Try checking the connection again shortly.")
        default: throw APIError.message("TheTVDB is unavailable right now (\(status)).")
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError.message("TheTVDB sent an unexpected reply.") }
    }
}
