import Foundation

/// The app's settings as a backup carries them (Drive, Files and Export): JellySpace's, the Customise
/// layout, the saved filters, the theme and the rest of Settings. No backup held any of them, so a
/// reinstall started every one again. Keys and sign-ins aren't settings: they stay in the Keychain.
@MainActor enum SettingsBackup {
    nonisolated private static let names: Set<String> = [
        "theme", "nativeAppearance", "publicRatingSource", "hideSpoilers", "launchTab", "use24HourTime", "streamingRegion",
        "animeEnglishTitles", "ignoreTitleArticles", "confirmDeletions", "haptics.enabled", "library.savedFilters", "library.savedLists",
        "library.list", "library.genreRows", "library.sort",
    ]
    nonisolated private static let families = ["jellyspace.", "customise."]
    /// Kept under JellySpace's names but not settings: who's signed in, this install's id, what you've
    /// seen, a session's counters, and what was learned about the server's pictures.
    nonisolated private static let notSettings = [
        "jellyspace.account.", "jellyspace.userID", "jellyspace.userServer", "jellyspace.deviceID", "jellyspace.seenUnwatched",
        "jellyspace.discover.turn", "jellyspace.posterHasTitle", "jellyspace.seerr.on",
        // Which server and user the TV's sign-in is for (the sign-in itself is in the Keychain).
        "jellyspace.cast.",
    ]
    nonisolated static func carries(_ key: String) -> Bool {
        if names.contains(key) { return true }
        return families.contains { key.hasPrefix($0) } && !notSettings.contains { key.hasPrefix($0) }
    }

    /// The settings you've changed (one never touched keeps following the app's own default).
    static func data(_ defaults: UserDefaults = .standard) -> Data? {
        let kept = defaults.dictionaryRepresentation().filter { carries($0.key) }
        guard !kept.isEmpty, PropertyListSerialization.propertyList(kept, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: kept, format: .binary, options: 0)
    }
    /// Puts them back, as the rest of a backup comes back: what's set on this phone now stays.
    static func restore(_ data: Data?, to defaults: UserDefaults = .standard) {
        guard let data, let kept = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return }
        for (key, value) in kept where carries(key) && defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        SavedFilters.shared.reload()
        SavedLists.shared.reload()
    }
}
