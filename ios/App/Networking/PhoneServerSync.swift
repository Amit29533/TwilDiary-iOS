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
    /// The Your server switch changed (Connections or Sync & backup): on, the extras get in step
    /// (and, the first time, your server's old copy gives the phone what it lacks); off, the
    /// server is left alone (its copy stays).
    @MainActor static func switched(_ on: Bool, store: DiaryStore) {
        guard on else { PhoneServerSync.shared.forget(); return }
        Task {
            await ServerExtrasMove.runOnce(store: store)
            await PhoneServerSync.shared.pullIfDue(store: store, force: true)
        }
    }
}

/// Keeps the phone's extras in step with a copy on your TwilDiary server (`/api/phone-extras`), the
/// same file and the same rules as Google Drive: read the server's copy, merge (the newer change
/// wins), and save back only what it was missing, so a new, empty install never overwrites it.
/// The server is reached with the app's built-in Cloudflare Access service token alone: your
/// server's Access policy admits it and the server takes it as you (owner's choice: no extra
/// sign-in). The diary itself stays on Trakt, MDBList, WeTrakr or this phone.
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
    private struct Copy: Decodable { let body: String?; let updatedAt: String? }

    private var available: Bool { ExtrasStorage.server && (store?.phoneOnly ?? false) }

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
    /// Turned off (the copy on the server stays). A server session saved by an older build goes.
    func forget() {
        pending?.cancel()
        _ = KeychainProviderSecretStore().writeSecret(nil, for: "extrasServer.session")
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

    /// Any call to your server with this session (server backups use it with no server diary).
    func send(_ path: String, method: String, body: Data? = nil, store: DiaryStore) async throws -> Data {
        self.store = store
        return try await request(path, method: method, body: body)
    }
    /// A request to your server, let in by the app's service token.
    private func request(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        guard AppConfiguration.accessServiceToken != nil else {
            throw APIError.message("This build has no key for your server, so it can’t reach it.")
        }
        // A query ("?section=titles") stays a query, not part of the path.
        let parts = path.split(separator: "?", maxSplits: 1)
        var url = AppConfiguration.backend.appendingPathComponent(String(parts[0].dropFirst()))
        if parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(parts[1]); url = components.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AppConfiguration.passAccess(&request)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(AppConfiguration.backend.absoluteString, forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), (response as? HTTPURLResponse)?.mimeType == "application/json" else {
            throw APIError.message(Self.explain(status, data, response))
        }
        return data
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
