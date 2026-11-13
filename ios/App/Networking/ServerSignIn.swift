import Foundation
import TwilDiaryCore

/// Your server's sign-in only signs you in (owner's rule): the diary lives on Trakt, MDBList,
/// WeTrakr or this phone, never on the server. The server's 30-day session is kept for what you
/// use it for, backups and extras, and the first time, what your server's old copy of the diary
/// holds that the phone doesn't (tags, Queue, long notes, statuses, folders, favourite people) is
/// copied onto the phone, so nothing is lost.
extension DiaryStore {
    func signInWithServer(_ credential: AccessCredential) async {
        PhoneServerSync.shared.adopt(token: credential.token, expires: credential.expires ?? now.addingTimeInterval(30 * 86_400))
        ExtrasStorage.server = true
        // The diary where you keep it: the service you signed in to on this phone, else this phone.
        let signedIn = Self.savedPhoneOnly.flatMap { tracker in
            (tracker == .trakt ? traktSignedInOnPhone : providerSettings.config(for: tracker.provider).isAuthenticated) ? tracker : nil
        } ?? (traktSignedInOnPhone ? .trakt : nil)
        if let signedIn { await startPhoneOnly(signedIn) } else { await startOnThisPhone() }
        await ServerExtrasMove.runOnce(store: self)
        await PhoneServerSync.shared.pullIfDue(store: self, force: true)
    }
}

/// Once: your server's old copy of the diary gives the phone what it doesn't have yet. What's on
/// the phone already wins; nothing is removed anywhere.
@MainActor enum ServerExtrasMove {
    static let doneKey = "serverExtras.moved"
    static func runOnce(store: DiaryStore) async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        do {
            let titles: [MediaTitle] = try await pages("titles", store: store)
            let locations: [FileLocation] = try await pages("locations", store: store)
            PhoneExtras.shared.restore(nil, archive: DiaryExport(workspace: Workspace(titles: titles, locations: locations)))
            struct Page: Decodable { let items: [Remote] }
            struct Remote: Decodable { let kind: String; let ref: Int; let name: String; let image: String?; let subtitle: String?; let savedAt: String }
            if let data = try? await PhoneServerSync.shared.send("/api/favourites", method: "GET", store: store),
               let page = try? JSONDecoder().decode(Page.self, from: data) {
                FavouritesStore.shared.merge(page.items.compactMap { remote in
                    Favourite.Kind(rawValue: remote.kind).map { Favourite(kind: $0, ref: remote.ref, name: remote.name, image: remote.image, subtitle: remote.subtitle,
                                                                          savedAt: DiaryDate.parse(remote.savedAt) ?? .distantPast) }
                })
            }
            UserDefaults.standard.set(true, forKey: doneKey)
            store.applyDiarySource()
        } catch {
            // Offline, or the server's sign-in refused: tried again at the next launch.
        }
    }
    private static func pages<T: Decodable & Sendable>(_ section: String, store: DiaryStore) async throws -> [T] {
        var result: [T] = [], after: String?, seen = Set<String>()
        repeat {
            var query = URLComponents()
            query.queryItems = [URLQueryItem(name: "section", value: section)] + (after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
            let data = try await PhoneServerSync.shared.send("/api/workspace?" + (query.percentEncodedQuery ?? ""), method: "GET", store: store)
            let page = try JSONDecoder().decode(WorkspacePage<T>.self, from: data)
            result += page.items; after = page.next
            if let next = after, !seen.insert(next).inserted { break }
        } while after != nil
        return result
    }
}
