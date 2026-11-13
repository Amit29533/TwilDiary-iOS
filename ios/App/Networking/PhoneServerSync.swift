import Foundation
import TwilDiaryCore

/// Where the phone's extras (tags, Queue, full notes, statuses a service can't keep, Jellyfin
/// folders, favourite people, the phone's Trash) are kept besides this iPhone while the diary lives
/// on a service alone. Any of them, together: Google Drive, your TwilDiary server, or both.
enum ExtrasStorage {
    static let driveKey = "extras.toDrive", serverKey = "extras.toServer"
    /// Google Drive (on unless turned off: it was the only place before).
    static var drive: Bool {
        get { UserDefaults.standard.object(forKey: driveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: driveKey) }
    }
    /// Your TwilDiary server on Cloudflare.
    static var server: Bool {
        get { UserDefaults.standard.bool(forKey: serverKey) }
        set { UserDefaults.standard.set(newValue, forKey: serverKey) }
    }
}

/// Keeps the phone's extras in step with a copy on your TwilDiary server (`/api/phone-extras`), the
/// same file and the same rules as Google Drive: read the server's copy, merge (the newer change
/// wins), and save back only what it was missing, so a new, empty install never overwrites it.
/// The server is reached with your Trakt sign-in on this iPhone (the server checks it's the Trakt
/// account linked to your diary and issues a session, kept in the Keychain) and, behind Cloudflare
/// Access, the built-in service token. The diary itself stays on Trakt.
@MainActor @Observable final class PhoneServerSync {
    static let shared = PhoneServerSync()
    private(set) var lastSynced: Date?
    private(set) var problem: String?
    private(set) var running = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastPull: Date?
    /// A change saved while a sync was running: it goes in one more pass right after.
    @ObservationIgnored private var again = false
    @ObservationIgnored weak var store: DiaryStore?
    private static let sessionAccount = "extrasServer.session"

    private struct Session: Codable { let token: String; let expires: Date? }
    private struct Copy: Decodable { let body: String?; let updatedAt: String? }

    private var available: Bool { ExtrasStorage.server && (store?.phoneOnly ?? false) && !(store?.onThisPhone ?? true) }

    /// Saves to the server a few seconds after the last change (a run of edits goes once).
    func soon() {
        guard available else { return }
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            _ = try? await self.run()
        }
    }
    /// When the app opens (at most once a minute) and when it's turned on.
    func pullIfDue(store: DiaryStore, force: Bool = false) async {
        self.store = store
        guard available, force || Date.now.timeIntervalSince(lastPull ?? .distantPast) > 60 else { return }
        if (try? await run()) == true { store.applyDiarySource() }
    }
    /// Turning it off forgets the server session (the copy on the server stays).
    func forget() {
        pending?.cancel()
        _ = KeychainProviderSecretStore().writeSecret(nil, for: Self.sessionAccount)
        lastSynced = nil; problem = nil
    }

    /// Reads, merges and saves back. Returns whether the phone's copy changed.
    @discardableResult func run() async throws -> Bool {
        guard available else { return false }
        guard !running else { again = true; return false }
        running = true
        defer {
            running = false
            if again { again = false; soon() }
        }
        do {
            let extras = PhoneExtras.shared
            let data = try await request("/api/phone-extras", method: "GET")
            lastPull = .now
            let copy = try JSONDecoder().decode(Copy.self, from: data)
            var result: (local: Bool, remote: Bool) = (false, true)
            if let body = copy.body {
                // A copy this app can't read (a newer version's) is left alone, not overwritten.
                guard let remote = try? JSONDecoder().decode(PhoneExtras.DriveCopy.self, from: Data(body.utf8)) else {
                    problem = "Your server has extras from a newer TwilDiary. Update the app to sync them."
                    return false
                }
                result = extras.merge(remote)
            } else if extras.driveCopy.entries.isEmpty, extras.driveCopy.locations.isEmpty,
                      FavouritesStore.shared.items.isEmpty, PhoneTrash.shared.titles.isEmpty {
                lastSynced = .now; problem = nil
                return false
            }
            if result.remote {
                let body = String(decoding: try JSONEncoder().encode(extras.driveCopy), as: UTF8.self)
                _ = try await request("/api/phone-extras", method: "PUT", body: try JSONSerialization.data(withJSONObject: ["body": body]))
            }
            lastSynced = .now; problem = nil
            return result.local
        } catch {
            problem = error.localizedDescription
            throw error
        }
    }

    /// A request to your server with the extras session (a fresh one once when it's refused).
    private func request(_ path: String, method: String, body: Data? = nil, retried: Bool = false) async throws -> Data {
        let token = try await session(fresh: retried)
        var request = URLRequest(url: AppConfiguration.backend.appendingPathComponent(String(path.dropFirst())), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        AppConfiguration.passAccess(&request)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(AppConfiguration.backend.absoluteString, forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried { return try await self.request(path, method: method, body: body, retried: true) }
        guard (200..<300).contains(status), (response as? HTTPURLResponse)?.mimeType == "application/json" else {
            throw APIError.message(Self.explain(status, data, response))
        }
        return data
    }

    /// The saved session, or a new one from your server for this iPhone's Trakt sign-in.
    private func session(fresh: Bool) async throws -> String {
        let keychain = KeychainProviderSecretStore()
        if !fresh, let saved = ((try? keychain.readSecret(for: Self.sessionAccount)) ?? nil).flatMap({ try? JSONDecoder().decode(Session.self, from: Data($0.utf8)) }),
           (saved.expires ?? .distantFuture) > Date.now.addingTimeInterval(3_600) {
            return saved.token
        }
        guard let store, store.traktSignedInOnPhone else { throw APIError.message("Sign in to Trakt on this iPhone first: your server checks that it's your diary's Trakt account.") }
        let trakt = try await store.traktToken()
        var request = URLRequest(url: AppConfiguration.backend.appendingPathComponent("api/auth"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfiguration.backend.absoluteString, forHTTPHeaderField: "Origin")
        AppConfiguration.passAccess(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["method": "provider", "provider": "trakt", "accessToken": trakt.accessToken, "clientId": trakt.clientId])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["token"] as? String, AccessCookiePolicy.validToken(token) else {
            throw APIError.message("Signing in to your server: " + Self.explain(status, data, response))
        }
        let session = Session(token: token, expires: (json["expiresAt"] as? String).flatMap(DiaryDate.parse))
        if let encoded = try? JSONEncoder().encode(session) { _ = keychain.writeSecret(String(decoding: encoded, as: UTF8.self), for: Self.sessionAccount) }
        return token
    }

    /// What went wrong, in words, and who said it: your server's own message (JSON or plain text),
    /// or Cloudflare Access's page (401: the token isn't recognised; 403: it is, but no policy on
    /// this app lets it in).
    private static func explain(_ status: Int, _ data: Data, _ response: URLResponse? = nil) -> String {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let message = (json["error"] as? [String: Any])?["message"] as? String { return message }
        let mime = (response as? HTTPURLResponse)?.mimeType ?? ""
        if mime == "text/plain", let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return "Your server said: " + String(text.prefix(160)) + " (HTTP \(status))."
        }
        if AppConfiguration.accessServiceToken == nil {
            return "Your server is behind Cloudflare Access and this build has no service token, so it can't be reached from here."
        }
        if mime == "text/html" {
            switch status {
            case 401: return "Cloudflare Access doesn't recognise the service token (HTTP 401). Check its Client ID and Secret."
            case 403: return "Cloudflare Access recognises the service token but no policy on this app lets it in (HTTP 403). Add a Service Auth policy with this token to the Access app for twildiary-v2.amit29533.workers.dev."
            default: break
            }
        }
        return status == 0 ? "Your server couldn't be reached." : "Your server didn't answer as expected (HTTP \(status))."
    }
}
