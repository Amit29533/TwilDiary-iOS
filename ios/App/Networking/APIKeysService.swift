import Foundation
import Observation

/// One key Settings → APIs can replace. The server returns only its last four characters.
struct APIKeyStatus: Decodable, Identifiable, Sendable, Equatable {
    let name: String
    let service: String
    let label: String
    /// "saved" (replaced here), "server" (the Worker secret) or "missing".
    let source: String
    let hint: String?
    let updatedAt: String?
    var id: String { name }
}
struct APIKeyCheck: Decodable, Sendable, Equatable { let ok: Bool; let message: String }

@MainActor @Observable final class APIKeysModel {
    private let store: DiaryStore
    private(set) var keys: [APIKeyStatus] = []
    private(set) var loaded = false
    private(set) var checks: [String: APIKeyCheck] = [:]
    private(set) var testing = Set<String>()
    private(set) var saving = false
    var error: String?
    init(store: DiaryStore) { self.store = store }

    func load() async {
        do {
            #if DEBUG
            if store.isPreview { keys = keys.isEmpty ? Self.preview : keys; loaded = true; return }
            #endif
            struct Page: Decodable { let keys: [APIKeyStatus] }
            let page: Page = try await store.read("/api/settings/apis")
            keys = page.keys; loaded = true; error = nil
        } catch is CancellationError { }
        catch APIError.rejected(404, _) { self.error = "Your server doesn’t have Settings → APIs yet. It arrives with the next server update."; loaded = true }
        catch { self.error = error.localizedDescription; loaded = true }
    }
    /// Saves the new key, then asks its service whether it works.
    func save(_ name: String, value: String) async -> Bool {
        saving = true; defer { saving = false }
        do {
            #if DEBUG
            if store.isPreview {
                keys = keys.map { $0.name == name ? APIKeyStatus(name: name, service: $0.service, label: $0.label, source: "saved", hint: String(value.suffix(4)), updatedAt: store.now.formatted(.iso8601)) : $0 }
                checks[name] = APIKeyCheck(ok: true, message: "Working"); return true
            }
            #endif
            struct Receipt: Decodable { let name: String; let hint: String }
            let _: Receipt = try await store.read("/api/settings/apis/\(name)", method: "PUT", body: ["value": value])
            await load(); await test(name); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ name: String) async {
        do {
            #if DEBUG
            if store.isPreview {
                keys = keys.map { $0.name == name ? APIKeyStatus(name: name, service: $0.service, label: $0.label, source: "server", hint: "8f2c", updatedAt: nil) : $0 }
                checks[name] = nil; return
            }
            #endif
            struct Receipt: Decodable { let removed: Bool }
            let _: Receipt = try await store.read("/api/settings/apis/\(name)", method: "DELETE")
            checks[name] = nil; await load()
        } catch { self.error = error.localizedDescription }
    }
    func test(_ name: String) async {
        testing.insert(name); defer { testing.remove(name) }
        do {
            #if DEBUG
            if store.isPreview { checks[name] = keys.first { $0.name == name }?.source == "missing" ? APIKeyCheck(ok: false, message: "Not set") : APIKeyCheck(ok: true, message: "Working"); return }
            #endif
            checks[name] = try await store.read("/api/settings/apis/\(name)/test", method: "POST", body: [:])
        } catch { checks[name] = APIKeyCheck(ok: false, message: error.localizedDescription) }
    }

    #if DEBUG
    static let preview = [
        APIKeyStatus(name: "TMDB_ACCESS_TOKEN", service: "tmdb", label: "Read access token", source: "server", hint: "Q2xk", updatedAt: nil),
        APIKeyStatus(name: "TRAKT_CLIENT_ID", service: "trakt", label: "Client ID", source: "saved", hint: "7e1a", updatedAt: "2026-10-28T09:12:00Z"),
        APIKeyStatus(name: "TRAKT_PERSONAL_ACCESS_TOKEN", service: "trakt", label: "Personal access token", source: "missing", hint: nil, updatedAt: nil),
        APIKeyStatus(name: "CF_ANALYTICS_TOKEN", service: "cloudflare", label: "Analytics API token", source: "server", hint: "u9Zt", updatedAt: nil),
        APIKeyStatus(name: "CF_ACCOUNT_ID", service: "cloudflare", label: "Account ID", source: "server", hint: "fec7", updatedAt: nil)
    ]
    #endif
}
