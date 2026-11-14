import Foundation
import Observation
import TwilDiaryCore

/// Your account on each service, as Cinopsys shows it in its list: your profile picture, your
/// name and your plan (Free, VIP…). Read from each service's own account page once in a while and
/// kept on this iPhone.
@MainActor @Observable final class AccountProfiles {
    static let shared = AccountProfiles()
    struct Account: Codable, Equatable, Sendable {
        var name: String?
        var avatar: String?
        var plan: String?
        var readAt: Date
    }
    private(set) var accounts: [String: Account] = AccountProfiles.load() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: Self.key) }
    }
    nonisolated private static let key = "accountProfiles"
    nonisolated private static func load() -> [String: Account] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Account].self, from: $0) } ?? [:]
    }
    @ObservationIgnored private var reading: Set<MainTracker> = []

    func account(_ tracker: MainTracker) -> Account? { accounts[tracker.rawValue] }
    func forget(_ tracker: MainTracker) { accounts[tracker.rawValue] = nil }

    /// Reads the account again when it's older than six hours (or `force`).
    func refresh(_ tracker: MainTracker, store: DiaryStore, force: Bool = false) async {
        guard !store.isPreview, !reading.contains(tracker) else { return }
        // A read that came back without a picture is tried again sooner (ten minutes).
        if !force, let saved = accounts[tracker.rawValue], Date.now.timeIntervalSince(saved.readAt) < (saved.avatar == nil ? 600 : 6 * 3600) { return }
        reading.insert(tracker)
        defer { reading.remove(tracker) }
        do {
            let data: Data
            switch tracker {
            case .trakt:
                data = try await TraktDirectStore.shared.client(store: store).get("/users/settings", query: ["extended": "full"]).data
            case .mdblist:
                data = try await store.directClient.read(await store.freshProviderConfig(.mdblist), path: "/user")
            case .wetrakr:
                data = try await store.directClient.read(await store.freshProviderConfig(.wetrakr), path: "/account/settings")
            case .simkl:
                // Simkl: user.name, user.avatar and account.type (free, pro, vip).
                guard let token = await SimklAccount.shared.token() else { return }
                data = try await SimklAPI(token: token).get("/users/settings")
            }
            accounts[tracker.rawValue] = Self.account(from: data, tracker: tracker)
        } catch { }
    }

    /// The name, picture and plan in a service's account reply. The services name these
    /// differently (Trakt: user.username, user.vip, user.images.avatar.full; MDBList: username,
    /// patron_status; WeTrakr: info.username, images.avatar, plan…; Simkl: user.name, user.avatar,
    /// account.type), so
    /// each is looked for where that service keeps it, then anywhere it might be.
    nonisolated static func account(from data: Data, tracker: MainTracker, now: Date = .now) -> Account {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let user = (root["user"] as? [String: Any]) ?? (root["account"] as? [String: Any]) ?? root
        func text(_ object: [String: Any], _ keys: [String]) -> String? {
            for key in keys { if let value = object[key] as? String, !value.isEmpty { return value } }
            return nil
        }
        // WeTrakr keeps the name under info (info.username, info.display_name).
        let info = user["info"] as? [String: Any] ?? [:]
        let name = text(user, ["username", "name", "slug", "display_name"]) ?? text(info, ["username", "display_name"]) ?? text(root, ["username", "name"])
            ?? ((root["account"] as? [String: Any])?["id"]).map { "\($0)" }
        var avatar: String?
        if let images = user["images"] as? [String: Any], let picture = images["avatar"] as? [String: Any] { avatar = text(picture, ["full", "medium"]) }
        // WeTrakr: images.avatar is just the file name on its storage.
        if avatar == nil, let images = user["images"] as? [String: Any] { avatar = text(images, ["avatar"]) }
        if avatar == nil, let picture = user["avatar"] as? [String: Any] { avatar = text(picture, ["full", "large", "medium", "url"]) }
        if avatar == nil { avatar = text(user, ["avatar", "avatar_url", "image", "picture"]) ?? text(root, ["avatar", "avatar_url"]) }
        if let found = avatar, found.hasPrefix("//") { avatar = "https:" + found }
        if let found = avatar, tracker == .wetrakr, !found.contains("://") {
            avatar = "https://api.wetrakr.com/uploads/avatars/" + (found.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? found)
        }
        var plan: String?
        if let vip = (user["vip"] as? Bool) ?? (root["vip"] as? Bool) { plan = vip ? "VIP" : "Free" }
        if plan == nil, let type = ((root["account"] as? [String: Any])?["type"] as? String) ?? (user["type"] as? String) ?? (user["plan"] as? String) {
            plan = type.lowercased() == "free" ? "Free" : type.uppercased().count <= 4 ? type.uppercased() : type.capitalized
        }
        if plan == nil, let patron = text(root, ["patron_status", "patreon_status"]) ?? text(user, ["patron_status"]) {
            plan = ["", "none", "free"].contains(patron.lowercased()) ? "Free" : "Supporter"
        }
        if plan == nil, tracker == .mdblist { plan = "Free" }
        return Account(name: name, avatar: avatar, plan: plan, readAt: now)
    }
}
