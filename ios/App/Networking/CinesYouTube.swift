import Foundation
import Security

/// Cines with a YouTube Data API key (owner's request, 25 Nov 2026): TwilDiary's own, built in as the
/// TMDB key is (`TWILDIARY_YOUTUBE_KEY` when building, from the repository secret; never in git), or
/// your own from Settings → APIs → YouTube, kept in this iPhone's Keychain. It is sent only to
/// YouTube, with the app's bundle id so a key restricted to the iOS app works. With it, Cines:
/// - asks YouTube for each clip's status before it shows (`statuses`): whether YouTube lets it play
///   in the app, whether it's public, and whether it's blocked in your country (1 unit for 50);
/// - reads further back through each official channel's uploads and Shorts (`playlist`, 1 unit for
///   50 videos);
/// - searches YouTube for scenes from titles in your diary (`search`, 100 units each, at most
///   `searchesPerDay` a day).
/// The free quota is 10,000 units a day. When it runs out, Cines goes on without the key until the
/// next day. Without a key, Cines reads the channels' public feeds and YouTube's oEmbed instead.
enum CinesYouTube {
    struct Video: Sendable {
        let id: String
        let title: String
        let channelID: String
        var channelTitle: String? = nil
    }

    static let searchesPerDay = 30

    // MARK: The key

    private static let keychainService = "com.amit29533.TwilDiary.youtube"
    nonisolated(unsafe) private static var cached: String??

    /// Your key, else the built-in one, unless YouTube said today's quota is used up.
    static var key: String? {
        guard !quotaUsedToday else { return nil }
        return savedKey ?? builtIn
    }
    static var builtIn: String? {
        guard let value = (Bundle.main.object(forInfoDictionaryKey: "TwilDiaryYouTubeKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
    static var savedKey: String? {
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let value = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cached = .some(value)
        return value
    }
    static func save(_ value: String?) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "key"]
        SecItemDelete(match as CFDictionary)
        cached = nil
        UserDefaults.standard.removeObject(forKey: quotaKey)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    /// "••••1FU"
    static func masked(_ key: String) -> String { "••••" + key.suffix(4) }

    /// Checks a key with YouTube (1 unit): nil when it works, else why not.
    static func test(_ key: String) async -> String? {
        do {
            _ = try await get("videos", ["part": "status", "id": "jNQXAC9IVRw"], key: key)
            return nil
        } catch let error as Failure {
            return error.message
        } catch {
            return FriendlyError.message(error)
        }
    }

    // MARK: The day's limits

    private static let quotaKey = "cines.youtube.quotaDay"
    private static let searchKey = "cines.youtube.searches"
    private static var today: String { Date().formatted(.iso8601.year().month().day()) }
    static var quotaUsedToday: Bool { UserDefaults.standard.string(forKey: quotaKey) == today }
    nonisolated static func quotaUsedUp() { UserDefaults.standard.set(Date().formatted(.iso8601.year().month().day()), forKey: quotaKey) }
    /// Takes one of today's searches, if any are left.
    static func takeSearch() -> Bool {
        let saved = UserDefaults.standard.string(forKey: searchKey) ?? ""
        let parts = saved.split(separator: "=")
        let used = parts.count == 2 && parts[0] == today ? Int(parts[1]) ?? 0 : 0
        guard used < searchesPerDay else { return false }
        UserDefaults.standard.set(today + "=" + String(used + 1), forKey: searchKey)
        return true
    }

    // MARK: Requests

    struct Failure: Error, Sendable { let message: String }

    nonisolated private static func get(_ path: String, _ query: [String: String], key: String) async throws -> [String: Any] {
        var parts = URLComponents(string: "https://www.googleapis.com/youtube/v3/" + path)!
        parts.queryItems = (query.sorted { $0.key < $1.key } + [("key", key)]).map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { throw Failure(message: "Invalid YouTube request.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // A key restricted to iOS apps checks this.
        if let bundle = Bundle.main.bundleIdentifier { request.setValue(bundle, forHTTPHeaderField: "X-Ios-Bundle-Identifier") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let error = object["error"] as? [String: Any]
            let reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
            if reason == "quotaExceeded" || reason == "dailyLimitExceeded" {
                quotaUsedUp()
                throw Failure(message: "Today's YouTube quota is used up.")
            }
            throw Failure(message: (error?["message"] as? String).map { "YouTube: " + $0 } ?? "YouTube refused the request.")
        }
        return object
    }

    struct Status: Sendable {
        let playable: Bool
        /// The channel that posted it ("Netflix").
        let channel: String?
    }

    /// Which of these videos YouTube will play in the app here (public, embedding allowed, and not
    /// blocked in your country), and the channel that posted each. nil when YouTube couldn't be asked.
    nonisolated static func statuses(_ ids: [String], key: String, region: String?) async -> [String: Status]? {
        guard !ids.isEmpty else { return [:] }
        var result: [String: Status] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            guard let object = try? await get("videos", ["part": "status,contentDetails,snippet", "id": chunk.joined(separator: ","), "maxResults": "50"], key: key) else { return nil }
            for id in chunk { result[id] = Status(playable: false, channel: nil) } // not returned: private or removed
            for item in object["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                let status = item["status"] as? [String: Any] ?? [:]
                var playable = status["embeddable"] as? Bool ?? false && (status["privacyStatus"] as? String ?? "public") != "private"
                if let region, let restriction = (item["contentDetails"] as? [String: Any])?["regionRestriction"] as? [String: Any] {
                    if let allowed = restriction["allowed"] as? [String], !allowed.contains(region) { playable = false }
                    if let blocked = restriction["blocked"] as? [String], blocked.contains(region) { playable = false }
                }
                result[id] = Status(playable: playable, channel: (item["snippet"] as? [String: Any])?["channelTitle"] as? String)
            }
        }
        return result
    }

    /// A page of a playlist (a channel's uploads, `UU…`, or its Shorts, `UUSH…`), newest first,
    /// and the next page's token.
    nonisolated static func playlist(_ id: String, page: String?, key: String) async -> (videos: [Video], next: String?)? {
        var query = ["part": "snippet", "playlistId": id, "maxResults": "50"]
        if let page { query["pageToken"] = page }
        guard let object = try? await get("playlistItems", query, key: key) else { return nil }
        let videos = (object["items"] as? [[String: Any]] ?? []).compactMap { item -> Video? in
            guard let snippet = item["snippet"] as? [String: Any], let title = snippet["title"] as? String,
                  let id = (snippet["resourceId"] as? [String: Any])?["videoId"] as? String,
                  id.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil,
                  title != "Private video", title != "Deleted video" else { return nil }
            return Video(id: id, title: title, channelID: snippet["videoOwnerChannelId"] as? String ?? "")
        }
        return (videos, object["nextPageToken"] as? String)
    }

    /// Videos YouTube finds for a search, embeddable ones only.
    nonisolated static func search(_ text: String, key: String, region: String?) async -> [Video] {
        var query = ["part": "snippet", "q": text, "type": "video", "videoEmbeddable": "true", "maxResults": "15",
                     "relevanceLanguage": "en", "safeSearch": "moderate"]
        if let region { query["regionCode"] = region }
        guard let object = try? await get("search", query, key: key) else { return [] }
        return (object["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = (item["id"] as? [String: Any])?["videoId"] as? String,
                  id.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil,
                  let snippet = item["snippet"] as? [String: Any], let title = snippet["title"] as? String else { return nil }
            return Video(id: id, title: CinesChannels.decode(title), channelID: snippet["channelId"] as? String ?? "",
                         channelTitle: (snippet["channelTitle"] as? String).map(CinesChannels.decode))
        }
    }

    /// Your country, for region blocks.
    static var region: String? { Locale.current.region?.identifier }
}
