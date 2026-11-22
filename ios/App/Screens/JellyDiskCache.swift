import Foundation

/// JellySpace's last loads kept on the phone between launches (the home's rows, Discover's shelves,
/// the recommendation index), so it opens on them at once and refreshes behind. Read and written off
/// the main thread; a file for another server or user is simply not used.
enum JellyDiskCache {
    private static var folder: URL { URL.applicationSupportDirectory.appending(path: "Jellyfin/Cache", directoryHint: .isDirectory) }

    static func save<Value: Encodable & Sendable>(_ value: Value, name: String) {
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appending(path: name + ".json"), options: .atomic)
        }
    }
    static func load<Value: Decodable & Sendable>(_ type: Value.Type, name: String) async -> Value? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: folder.appending(path: name + ".json")) else { return nil }
            return try? JSONDecoder().decode(Value.self, from: data)
        }.value
    }
    /// Signed out: nothing of the server is left on the phone.
    static func clear() {
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }
}

/// The home's rows as last loaded.
struct JellyHomeSnapshot: Codable, Sendable {
    let server: String
    let libraries: [JellyfinLibrary]
    let resume: [JellyfinClient.Item]
    let nextUp: [JellyfinClient.Item]
    let favourites: [JellyfinClient.Item]
    let collections: [JellyfinClient.Item]
    let latest: [String: [JellyfinClient.Item]]
    let forYou: JellyForYou?
}

/// Discover's shelves as last drawn (kept half a day: they're drawn at random, and drawing them again
/// on every launch changed the rows under you).
struct JellyDiscoverSnapshot: Codable, Sendable {
    let key: String
    let at: Date
    let discover: JellyDiscover
}

/// The recommendation index as last built.
struct JellyIndexSnapshot: Codable, Sendable {
    let key: String
    let at: Date
    let index: JellyLibraryIndex
}
