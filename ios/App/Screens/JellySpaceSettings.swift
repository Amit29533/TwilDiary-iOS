import SwiftUI
import Security
import Synchronization
import TwilDiaryCore

// MARK: Preferences

/// JellySpace's settings, kept in UserDefaults (read by @AppStorage in the pages and the player).
enum JellyPrefs {
    static let rowsKey = "jellyspace.home.rows"
    static let hiddenRowsKey = "jellyspace.home.hiddenRows"
    /// How many Dynamic recommendations rows the home shows (1 to 5): themed rows from words and tags.
    static let themeCountKey = "jellyspace.home.themeCount"
    /// My Media's order: library ids, comma-separated (any library not in it follows, in the server's order).
    static let mediaOrderKey = "jellyspace.home.mediaOrder"
    static let hiddenKey = "jellyspace.hidden"
    static let countsKey = "jellyspace.posters.counts"
    static let ticksKey = "jellyspace.posters.ticks"
    static let captionsKey = "jellyspace.posters.captions"
    static let skipIntroKey = "jellyspace.skip.intro"
    static let skipRecapKey = "jellyspace.skip.recap"
    static let skipCreditsKey = "jellyspace.skip.credits"
    static let introDBKey = "jellyspace.introdb"
    static let skipSecondsKey = "jellyspace.skipSeconds"
    static let autoplayKey = "jellyspace.autoplay"
    static let countdownKey = "jellyspace.countdown"
    static let resumeKey = "jellyspace.resume"
    /// The rating card a moment after a video starts (the rating and IMDb's warnings), as Netflix's.
    static let ratingCardKey = "jellyspace.playback.ratingCard"
    static let diaryKey = "jellyspace.diary"
    static let rememberTracksKey = "jellyspace.rememberTracks"
    static let swipeSeekKey = "jellyspace.gesture.seek"
    static let swipeLevelsKey = "jellyspace.gesture.levels"
    static let holdKey = "jellyspace.gesture.hold"
    static let seerrAddressKey = "jellyspace.seerr.address"
    static let fillKey = "jellyspace.fill"
    /// JellySpace behind Face ID (Preferences → Privacy), and the seconds away before it locks again.
    static let faceLockKey = "jellyspace.faceLock"
    static let faceLockAfterKey = "jellyspace.faceLock.after"
    static let faceLockAfterChoices: [(String, Int)] = [("Immediately", 0), ("After 1 minute", 60), ("After 5 minutes", 300), ("After 15 minutes", 900)]
    /// mpv's Fill and Original on its GPU output (on: styled subtitles kept, a second of black as it
    /// switches); off, Fill zooms at once on the AVFoundation output and the app draws the subtitles.
    static let gpuZoomKey = "jellyspace.mpv.gpuZoom"
    static let upscaleKey = "jellyspace.upscale"
    static let upscaleModeKey = "jellyspace.upscaleMode"
    static let skipDelayKey = "jellyspace.skip.delay"
    static let batteryKey = "jellyspace.battery"
    static let timeModeKey = "jellyspace.timeMode"
    static let subtitleLanguageKey = "jellyspace.subtitleSearchLanguage"
    static let lrclibKey = "jellyspace.lrclib"
    /// Sound: a dialogue lift in dB (0, 4, 7, 10), night mode, and a volume boost in percent (0, 50, 100, 200).
    static let dialogueKey = "jellyspace.audio.dialogue"
    static let nightKey = "jellyspace.audio.night"
    static let boostKey = "jellyspace.audio.boost"
    /// Subtitles' look: colour ("white", "yellow"), a box behind them, and how far up they sit (a
    /// share of the picture's height: 0, 0.06, 0.12).
    static let subtitleSizeKey = "jellyspace.subtitleSize"
    static let subtitleColorKey = "jellyspace.subtitle.color"
    static let subtitleBoxKey = "jellyspace.subtitle.box"
    static let subtitleRaiseKey = "jellyspace.subtitle.raise"
    /// "Are you still watching?" after this many episodes played on their own in a row (0: never).
    static let stillWatchingKey = "jellyspace.stillWatching"
}

/// The choices the player's menu and Settings offer for sound and subtitles.
enum JellySound {
    static let dialogue: [(String, Int)] = [("Off", 0), ("Low", 4), ("Medium", 7), ("High", 10)]
    static let boost: [(String, Int)] = [("Off", 0), ("+50%", 50), ("+100%", 100), ("+200%", 200)]
    static let subtitleSizes: [(String, Double)] = [("Small", 0.8), ("Medium", 1.0), ("Large", 1.3), ("Extra large", 1.6)]
    static let subtitleColors: [(String, String)] = [("White", "white"), ("Yellow", "yellow")]
    static let subtitleBackgrounds: [(String, Bool)] = [("Outline", false), ("Box", true)]
    static let subtitlePositions: [(String, Double)] = [("Bottom", 0), ("Higher", 0.06), ("Highest", 0.12)]
    static let stillWatching: [(String, Int)] = [("Never", 0), ("After 2 episodes", 2), ("After 3 episodes", 3), ("After 4 episodes", 4)]
}

/// The home's rows, in the order you set; any you turned off are left out.
enum JellyHomeRow: String, CaseIterable, Identifiable {
    case hero, resume, media, genres, top10, libraries, gems, tonight, forYou, themes, random, favourites, collections
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hero: "Top poster"
        case .media: "My Media"
        case .resume: "Continue Watching"
        case .favourites: "Favourites"
        case .libraries: "Library rows"
        case .genres: "Genres"
        case .top10: "Top 10"
        case .gems: "Hidden gems"
        case .tonight: "Tonight's genre"
        case .random: "Random picks"
        case .forYou: "For you"
        case .themes: "Dynamic recommendations"
        case .collections: "Collections"
        }
    }
    static func order(_ raw: String) -> [JellyHomeRow] {
        // The top poster and My Media always lead (they sit at the top): only the rows below are ordered.
        let saved = raw.split(separator: ",").compactMap { JellyHomeRow(rawValue: String($0)) }.filter { !$0.fixedAtTop }
        return saved + allCases.filter { !$0.fixedAtTop && !saved.contains($0) }
    }
    /// The top poster, and My Media's chips under the big title: on or off, not moved.
    var fixedAtTop: Bool { self == .hero || self == .media }
    /// Discover's sections (loaded together, once a session).
    static let discoverRows: Set<JellyHomeRow> = [.genres, .top10, .gems, .tonight, .random]
    static func hidden(_ raw: String) -> Set<JellyHomeRow> { Set(raw.split(separator: ",").compactMap { JellyHomeRow(rawValue: String($0)) }) }
}

/// How an intro, recap or the credits are skipped: not at all, with a button, or on their own.
/// Upscaling, as Infuse does it: Apple's own super resolution and MetalFX for video below 1080p.
/// Auto leaves 50 and 60 fps video alone (twice the frames for the same budget); Always takes it too.
enum JellyUpscale: String, CaseIterable {
    case off, auto, always
    var title: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .always: "Always"
        }
    }
    /// Before there were three choices it was on or off: on becomes Auto.
    static var initial: JellyUpscale {
        UserDefaults.standard.bool(forKey: JellyPrefs.upscaleKey) ? .auto : .off
    }
    /// Whether a video at this frame rate is upscaled (an unknown rate counts as a usual one).
    func applies(frameRate: Double) -> Bool {
        switch self {
        case .off: false
        case .auto: frameRate < 49
        case .always: true
        }
    }
}

/// My Media's pills in your order (Settings → JellySpace → My Media); a library not placed yet
/// (a new one) follows, in the server's order.
enum JellyMediaOrder {
    static func sorted(_ libraries: [JellyfinLibrary], _ raw: String) -> [JellyfinLibrary] {
        let saved = raw.split(separator: ",").map(String.init)
        let placed = saved.compactMap { id in libraries.first { $0.id == id } }
        return placed + libraries.filter { library in !placed.contains { $0.id == library.id } }
    }
}

/// One section of JellySpace's home: a fixed one (Continue Watching, Top 10…), or one library's
/// Recently added or Random row. Each has its own place and switch in Settings → JellySpace.
struct JellyHomeSection: Hashable, Identifiable {
    enum Kind: Hashable { case fixed(JellyHomeRow), latest(String), random(String) }
    let kind: Kind
    let title: String
    var id: String {
        switch kind {
        case .fixed(let row): row.rawValue
        case .latest(let library): "latest:" + library
        case .random(let library): "random:" + library
        }
    }
}

extension JellyHomeRow {
    /// The home's sections below the top poster, in your order. Each library's Recently added row
    /// stands where "Library rows" stood, each film or show library's Random row where "Random
    /// picks" stood, and a section that's new since you last arranged them (a new library, say)
    /// goes in after its neighbour.
    static func sections(_ raw: String, libraries: [JellyfinLibrary]) -> [JellyHomeSection] {
        let latest = libraries.map { JellyHomeSection(kind: .latest($0.id), title: "Recently added · " + $0.name) }
        let random = libraries.filter(JellyDiscover.holdsVideo)
            .map { JellyHomeSection(kind: .random($0.id), title: "Random from " + $0.name) }
        let defaults: [JellyHomeSection] = allCases.filter { !$0.fixedAtTop }.flatMap { row -> [JellyHomeSection] in
            switch row {
            case .libraries: latest
            case .random: random
            default: [JellyHomeSection(kind: .fixed(row), title: row.title)]
            }
        }
        let byID = Dictionary(defaults.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: [JellyHomeSection] = []
        for id in expand(raw, latest: latest.map(\.id), random: random.map(\.id)) {
            if let section = byID[id], !placed.contains(section) { placed.append(section) }
        }
        for (index, section) in defaults.enumerated() where !placed.contains(section) {
            if let anchor = defaults[..<index].last(where: { placed.contains($0) }), let at = placed.firstIndex(of: anchor) {
                placed.insert(section, at: at + 1)
            } else {
                placed.insert(section, at: 0)
            }
        }
        return placed
    }
    /// The sections switched off, by id. An old "Library rows" or "Random picks" switch covers every
    /// library's row of that kind.
    static func hiddenSections(_ raw: String, libraries: [JellyfinLibrary]) -> Set<String> {
        Set(expand(raw, latest: libraries.map { "latest:" + $0.id },
                   random: libraries.filter(JellyDiscover.holdsVideo).map { "random:" + $0.id }))
    }
    /// A saved list with the old whole-group entries opened out into one per library (kept as they
    /// were while the libraries aren't known yet).
    private static func expand(_ raw: String, latest: [String], random: [String]) -> [String] {
        raw.split(separator: ",").map(String.init).flatMap { token -> [String] in
            switch token {
            case JellyHomeRow.libraries.rawValue where !latest.isEmpty: latest
            case JellyHomeRow.random.rawValue where !random.isEmpty: random
            default: [token]
            }
        }
    }
}

enum JellySkipMode: String, CaseIterable {
    case off = "Off", button = "Button", auto = "Automatic"
}

/// Libraries, folders, shows and films you hid from JellySpace (id → name, so they can be listed).
enum JellyHidden {
    /// The list as last decoded: the home filters every row through it, twenty and more times a
    /// redraw, and it only changes when you hide or show something.
    private static let decoded = Mutex<(raw: String, items: [String: String])>(("{}", [:]))
    static func decode(_ raw: String) -> [String: String] {
        if let kept = decoded.withLock({ $0.raw == raw ? $0.items : nil }) { return kept }
        let items = (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
        decoded.withLock { $0 = (raw, items) }
        return items
    }
    static func encode(_ items: [String: String]) -> String {
        (try? JSONEncoder().encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    static func hide(_ id: String, name: String) {
        var items = decode(UserDefaults.standard.string(forKey: JellyPrefs.hiddenKey) ?? "{}")
        items[id] = name
        UserDefaults.standard.set(encode(items), forKey: JellyPrefs.hiddenKey)
    }
    static func show(_ id: String) {
        var items = decode(UserDefaults.standard.string(forKey: JellyPrefs.hiddenKey) ?? "{}")
        items[id] = nil
        UserDefaults.standard.set(encode(items), forKey: JellyPrefs.hiddenKey)
    }
}

// MARK: Secrets and the signed-in account

/// JellySpace's own secrets in the Keychain (this device only): a signed-in user's token and the
/// Jellyseerr key.
enum JellySecrets {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.amit29533.TwilDiary.jellyspace", kSecAttrAccount as String: account]
    }
    static func read(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ account: String, _ value: String?) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// A Jellyfin user JellySpace signed in as (with a password or Quick Connect), for one server: their
/// token then stands in for the API key, so it shows and saves that user's things.
@MainActor enum JellyAccount {
    private static let userKey = "jellyspace.account.user", nameKey = "jellyspace.account.name", serverKey = "jellyspace.account.server"
    static var token: String? {
        guard let server = JellyfinSettings.address?.absoluteString, UserDefaults.standard.string(forKey: serverKey) == server else { return nil }
        // Read from the Keychain once (asked often: playback reports, the client).
        if cachedToken == nil { cachedToken = .some(JellySecrets.read("user-token")) }
        return cachedToken ?? nil
    }
    private static var cachedToken: String??
    static var userID: String? { token == nil ? nil : UserDefaults.standard.string(forKey: userKey) }
    static var userName: String? { token == nil ? nil : UserDefaults.standard.string(forKey: nameKey) }
    static func save(_ session: JellyAuth.Session) {
        guard let server = JellyfinSettings.address?.absoluteString else { return }
        UserDefaults.standard.set(server, forKey: serverKey)
        UserDefaults.standard.set(session.User.Id, forKey: userKey)
        UserDefaults.standard.set(session.User.Name, forKey: nameKey)
        JellySecrets.write("user-token", session.AccessToken)
        cachedToken = nil
        JellySpace.resetKey()
    }
    static func signOut() {
        for key in [userKey, nameKey, serverKey] { UserDefaults.standard.removeObject(forKey: key) }
        JellySecrets.write("user-token", nil)
        cachedToken = nil
        JellySpace.resetKey()
        // Nothing of the server kept on the phone.
        JellyDiskCache.clear()
    }
}

// MARK: The settings page

/// The pages under Settings → JellySpace, each holding one kind of setting.
enum JellySettingsPage: String, Hashable, CaseIterable {
    case preferences, home, libraries, playback, skipping, subtitles, sound, gestures, requests, musicDiary
    var title: String {
        switch self {
        case .preferences: "Preferences"
        case .home: "Home"
        case .libraries: "Libraries"
        case .playback: "Playback"
        case .skipping: "Skipping"
        case .subtitles: "Subtitles"
        case .sound: "Sound"
        case .gestures: "Gestures"
        case .requests: "Requests"
        case .musicDiary: "Music and diary"
        }
    }
    var symbol: String {
        switch self {
        case .preferences: "slider.horizontal.3"
        case .home: "house.fill"
        case .libraries: "books.vertical.fill"
        case .playback: "play.rectangle.fill"
        case .skipping: "forward.end.fill"
        case .subtitles: "captions.bubble.fill"
        case .sound: "speaker.wave.2.fill"
        case .gestures: "hand.draw.fill"
        case .requests: "tray.and.arrow.down.fill"
        case .musicDiary: "music.note"
        }
    }
    var tint: SettingsView.TileTint {
        switch self {
        case .preferences: .cyan
        case .home: .blue
        case .libraries: .indigo
        case .playback: .red
        case .skipping: .orange
        case .subtitles: .yellow
        case .sound: .pink
        case .gestures: .teal
        case .requests: .purple
        case .musicDiary: .green
        }
    }
}

/// The server's libraries, kept while the app runs so the Home and Libraries pages open with them.
@MainActor enum JellySettingsLibraries {
    static var cached: [JellyfinLibrary] = []
    static func load() async -> [JellyfinLibrary] {
        guard let client = JellySpace.client else { return cached }
        if let found = try? await client.libraries() { cached = found }
        return cached
    }
}

/// Settings → JellySpace, as iOS Settings is: your account at the top, then a row for each page in
/// three sections (JellySpace, Player, More), and the picture cache at the foot.
struct JellySpaceSettingsView: View {
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @AppStorage(JellyPrefs.seerrAddressKey) private var seerrAddress = ""
    @State private var libraries: [JellyfinLibrary] = JellySettingsLibraries.cached
    @State private var profiles: [JellyfinClient.Profile] = []
    @State private var watchingAs: String?
    /// Read once the page is up (building the page happens far more often).
    @State private var signedIn: String?
    @State private var signIn: JellySignInSheet.Mode?
    @State private var notice: String?

    var body: some View {
        let hiddenItems = JellyHidden.decode(hiddenRaw)
        let shownCount = libraries.filter { hiddenItems[$0.id] == nil }.count
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 22) {
                JellyAccountGroup(signedIn: $signedIn, watchingAs: $watchingAs, signIn: $signIn, profiles: profiles) {
                    Task { await load() }
                }
                SettingsGroup(label: "JellySpace") {
                    JellySettingsLink(page: .home)
                    SettingsDivider()
                    JellySettingsLink(page: .libraries, value: libraries.isEmpty ? nil : "\(shownCount) of \(libraries.count) shown")
                }
                SettingsGroup(label: "Player") {
                    JellyPreferencesLink()
                    SettingsDivider()
                    JellySettingsLink(page: .playback)
                    SettingsDivider()
                    JellySettingsLink(page: .skipping)
                    SettingsDivider()
                    JellySettingsLink(page: .subtitles)
                    SettingsDivider()
                    JellySettingsLink(page: .sound)
                    SettingsDivider()
                    JellySettingsLink(page: .gestures)
                }
                SettingsGroup(label: "More") {
                    JellySettingsLink(page: .requests, value: seerrAddress.isEmpty ? "Off" : "On")
                    SettingsDivider()
                    JellySettingsLink(page: .musicDiary)
                }
                JellyStorageGroup(notice: $notice)
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("JellySpace")
        .task {
            signedIn = JellyAccount.userName
            await load()
        }
        .sheet(item: $signIn, onDismiss: { signedIn = JellyAccount.userName; Task { await load() } }) { JellySignInSheet(mode: $0) }
    }

    /// The libraries, who you watch as and the server's users, set together at the end (each set
    /// redraws the page).
    private func load() async {
        guard let client = JellySpace.client else { return }
        let found = await JellySettingsLibraries.load()
        let user = await JellyfinUser.id(client)
        let people = JellyAccount.token == nil ? ((try? await client.profiles()) ?? []) : []
        if found != libraries { libraries = found }
        watchingAs = user
        profiles = people
    }
}

/// A row on the main page: the page's tile and name, what it's set to (when that says something),
/// and the chevron; it opens the page.
private struct JellySettingsLink: View {
    let page: JellySettingsPage
    var value: String? = nil
    var body: some View {
        NavigationLink(value: page) {
            HStack(spacing: 14) {
                tile
                Text(page.title).font(.system(size: ThemeStore.current.native ? 17 : 15, weight: ThemeStore.current.native ? .regular : .semibold))
                    .foregroundStyle(HomeStyle.primary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let value { Text(value).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                SettingsChevron()
            }
            .settingsRowFrame().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("jellyspace-settings-" + page.rawValue)
    }
    @ViewBuilder private var tile: some View {
        if ThemeStore.current.native {
            NativeTile(symbol: page.symbol, size: 30, color: page.tint.system)
        } else {
            Image(systemName: page.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(HomeStyle.chipText)
                .frame(width: 38, height: 38).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
        }
    }
}

/// One page under Settings → JellySpace, in sections.
struct JellySettingsPageView: View {
    let page: JellySettingsPage
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @State private var libraries: [JellyfinLibrary] = JellySettingsLibraries.cached

    var body: some View {
        let hiddenItems = JellyHidden.decode(hiddenRaw)
        let shown = libraries.filter { hiddenItems[$0.id] == nil }
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 22) {
                switch page {
                case .home:
                    JellyHomeRowsGroup(shown: shown)
                    JellyDynamicGroup()
                    JellyMyMediaGroup(shown: shown)
                    JellyPostersGroup()
                case .libraries:
                    JellyLibrariesGroup(libraries: libraries, hiddenItems: hiddenItems, hiddenRaw: $hiddenRaw)
                case .preferences: JellyPreferencesGroups()
                case .playback: JellyPlaybackGroups()
                case .skipping: JellySkippingGroups()
                case .subtitles: JellySubtitlesGroups()
                case .sound: JellySoundGroup()
                case .gestures: JellyGesturesGroup()
                case .requests: JellyRequestsGroup()
                case .musicDiary: JellyMusicDiaryGroups()
                }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation(page.title)
        .task {
            guard page == .home || page == .libraries else { return }
            let found = await JellySettingsLibraries.load()
            if found != libraries { libraries = found }
        }
    }
}

/// The rows the settings groups are made of.
@MainActor private enum JellySettingsRows {
    static func toggle(_ title: String, _ value: Binding<Bool>, accent: Color) -> some View {
        SettingsLine(title: title) { Toggle("", isOn: value).labelsHidden().tint(accent).accessibilityLabel(title) }
    }
    static func choice<Value: Hashable>(_ title: String, _ value: Binding<Value>, _ options: [(String, Value)]) -> some View {
        SettingsLine(title: title) {
            Menu {
                Picker(title, selection: value) { ForEach(options, id: \.1) { Text($0.0).tag($0.1) } }
            } label: { menuLabel(options.first { $0.1 == value.wrappedValue }?.0 ?? "") }
                .accessibilityLabel(title)
        }
    }
    static func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 15))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
        }.foregroundStyle(HomeStyle.secondary)
    }
    static func button(_ title: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(accent)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    static func move(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.07), in: Circle())
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1).accessibilityLabel(label)
    }
}

// MARK: Account

private struct JellyAccountGroup: View {
    @Binding var signedIn: String?
    @Binding var watchingAs: String?
    @Binding var signIn: JellySignInSheet.Mode?
    let profiles: [JellyfinClient.Profile]
    let reload: () -> Void
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        SettingsGroup(label: "Account") {
            if let signedIn {
                SettingsLine(title: signedIn) {
                    Button("Sign out") {
                        JellyAccount.signOut()
                        self.signedIn = nil
                        reload()
                    }.font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent).accessibilityIdentifier("jellyspace-sign-out")
                }
            } else {
                if !profiles.isEmpty {
                    SettingsLine(title: "Watching as") {
                        Menu {
                            ForEach(profiles) { profile in
                                Button {
                                    if let server = JellyfinSettings.address?.absoluteString { JellyfinUser.choose(profile.Id, server: server) }
                                    watchingAs = profile.Id
                                } label: { Label(profile.Name ?? "User", systemImage: watchingAs == profile.Id ? "checkmark" : "person") }
                            }
                        } label: { JellySettingsRows.menuLabel(profiles.first { $0.Id == watchingAs }?.Name ?? "Choose") }
                            .accessibilityIdentifier("jellyspace-watching-as")
                    }
                    SettingsDivider()
                }
                JellySettingsRows.button("Sign in with Quick Connect", accent: theme.accent) { signIn = .quick }
                SettingsDivider()
                JellySettingsRows.button("Sign in with password", accent: theme.accent) { signIn = .password }
            }
        }
    }
}

// MARK: Home rows, My Media and what's hidden

/// Dynamic recommendations: how many themed rows the home shows ("Recommendations for Rain",
/// "Random picks for Dance", "Must watch Parks"), from the words and tags across your server.
private struct JellyDynamicGroup: View {
    @AppStorage(JellyPrefs.themeCountKey) private var count = 3
    private static let counts = (1...5).map { ($0 == 1 ? "1 row" : "\($0) rows", $0) }
    var body: some View {
        SettingsGroup(label: "Dynamic recommendations") {
            JellySettingsRows.choice("Rows on the home", $count, Self.counts)
        }
        JellyDecoderNote(text: "Rows from words and tags your titles share: Recommendations for, Random picks for, Must watch. They change every day.")
    }
}

private struct JellyHomeRowsGroup: View {
    let shown: [JellyfinLibrary]
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.rowsKey) private var rowsRaw = ""
    @AppStorage(JellyPrefs.hiddenRowsKey) private var hiddenRowsRaw = ""

    var body: some View {
        let order = JellyHomeRow.sections(rowsRaw, libraries: shown)
        let off = JellyHomeRow.hiddenSections(hiddenRowsRaw, libraries: shown)
        SettingsGroup(label: "Home") {
            ForEach([JellyHomeRow.hero, .media]) { row in
                if row == .media { SettingsDivider() }
                JellySettingsRows.toggle(row.title, Binding(get: { !off.contains(row.rawValue) }, set: { on in
                    setHidden(row.rawValue, hidden: !on, in: off)
                }), accent: theme.accent)
            }
            ForEach(Array(order.enumerated()), id: \.element.id) { position, section in
                SettingsDivider()
                HStack(spacing: 10) {
                    Text(section.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                    Spacer(minLength: 8)
                    JellySettingsRows.move("chevron.up", label: "Move \(section.title) up", disabled: position == 0) { move(section, by: -1, in: order) }
                    JellySettingsRows.move("chevron.down", label: "Move \(section.title) down", disabled: position == order.count - 1) { move(section, by: 1, in: order) }
                    Toggle("", isOn: Binding(get: { !off.contains(section.id) }, set: { on in
                        setHidden(section.id, hidden: !on, in: off)
                    })).labelsHidden().tint(theme.accent).accessibilityLabel(section.title)
                }.padding(.horizontal, 16).frame(minHeight: 50)
            }
        }
    }
    private func setHidden(_ id: String, hidden: Bool, in off: Set<String>) {
        var next = off
        if hidden { next.insert(id) } else { next.remove(id) }
        hiddenRowsRaw = next.sorted().joined(separator: ",")
    }
    private func move(_ section: JellyHomeSection, by step: Int, in order: [JellyHomeSection]) {
        guard let at = order.firstIndex(of: section), order.indices.contains(at + step) else { return }
        var next = order
        next.swapAt(at, at + step)
        rowsRaw = next.map(\.id).joined(separator: ",")
    }
}

/// My Media: the libraries shown on the home, in the order of their pills, each moved with ▲ ▼.
private struct JellyMyMediaGroup: View {
    let shown: [JellyfinLibrary]
    @AppStorage(JellyPrefs.mediaOrderKey) private var mediaOrderRaw = ""
    @AppStorage(JellyRecommendOff.key) private var offRaw = ""
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        let order = JellyMediaOrder.sorted(shown, mediaOrderRaw)
        if !order.isEmpty {
            SettingsGroup(label: "My Media") {
                ForEach(Array(order.enumerated()), id: \.element.id) { position, library in
                    if position > 0 { SettingsDivider() }
                    HStack(spacing: 10) {
                        Label(library.name, systemImage: JellySpace.symbol(library.type))
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        // In recommendations: off keeps it out of More like this, the dynamic rows and the rest.
                        Toggle("", isOn: recommends(library)).labelsHidden().tint(theme.accent)
                            .accessibilityLabel("Recommend from \(library.name)")
                            .accessibilityIdentifier("jellyspace-recommend-" + library.id)
                        JellySettingsRows.move("chevron.up", label: "Move \(library.name) up", disabled: position == 0) { moveLibrary(library, by: -1, in: order) }
                        JellySettingsRows.move("chevron.down", label: "Move \(library.name) down", disabled: position == order.count - 1) { moveLibrary(library, by: 1, in: order) }
                    }.padding(.horizontal, 16).frame(minHeight: 50).accessibilityIdentifier("jellyspace-media-order-" + library.id)
                }
            }
            JellyDecoderNote(text: "The switch beside each: off keeps a library out of recommendations (More like this, Dynamic recommendations, the top poster, For you, Top 10, Hidden gems, the random rows). It stays in My Media and you can still browse it.")
        }
    }
    /// On: the library's titles can be recommended; off: they never are.
    private func recommends(_ library: JellyfinLibrary) -> Binding<Bool> {
        Binding(get: { !JellyRecommendOff.ids(offRaw).contains(library.id) }, set: { on in
            var off = JellyRecommendOff.ids(offRaw)
            if on { off.remove(library.id) } else { off.insert(library.id) }
            offRaw = off.sorted().joined(separator: ",")
        })
    }
    private func moveLibrary(_ library: JellyfinLibrary, by step: Int, in order: [JellyfinLibrary]) {
        guard let at = order.firstIndex(where: { $0.id == library.id }), order.indices.contains(at + step) else { return }
        var next = order
        next.swapAt(at, at + step)
        // Hidden libraries keep their places for when they're shown again.
        let kept = mediaOrderRaw.split(separator: ",").map(String.init).filter { id in !next.contains { $0.id == id } }
        mediaOrderRaw = (next.map(\.id) + kept).joined(separator: ",")
    }
}

/// Every library with its switch, then anything else you hid (a folder, a show) to show again.
private struct JellyLibrariesGroup: View {
    let libraries: [JellyfinLibrary]
    let hiddenItems: [String: String]
    @Binding var hiddenRaw: String
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        let libraryIDs = Set(libraries.map(\.id))
        let others = hiddenItems.filter { !libraryIDs.contains($0.key) }.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        SettingsGroup(label: "Libraries") {
            if libraries.isEmpty && others.isEmpty {
                SettingsLine(title: "No libraries") { EmptyView() }
            }
            ForEach(Array(libraries.enumerated()), id: \.element.id) { position, library in
                if position > 0 { SettingsDivider() }
                JellySettingsRows.toggle(library.name, Binding(get: { hiddenItems[library.id] == nil }, set: { on in
                    if on { JellyHidden.show(library.id) } else { JellyHidden.hide(library.id, name: library.name) }
                    hiddenRaw = UserDefaults.standard.string(forKey: JellyPrefs.hiddenKey) ?? "{}"
                }), accent: theme.accent)
            }
            ForEach(others, id: \.key) { entry in
                SettingsDivider()
                SettingsLine(title: entry.value) {
                    Button("Show") {
                        JellyHidden.show(entry.key)
                        hiddenRaw = UserDefaults.standard.string(forKey: JellyPrefs.hiddenKey) ?? "{}"
                    }.font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                }
            }
        }
    }
}

// MARK: Posters

private struct JellyPostersGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.countsKey) private var counts = true
    @AppStorage(JellyPrefs.ticksKey) private var ticks = true
    @AppStorage(JellyPrefs.captionsKey) private var captions = true

    var body: some View {
        SettingsGroup(label: "Posters") {
            JellySettingsRows.toggle("Unwatched counts", $counts, accent: theme.accent)
            SettingsDivider()
            JellySettingsRows.toggle("Watched ticks", $ticks, accent: theme.accent)
            SettingsDivider()
            JellySettingsRows.toggle("Titles", $captions, accent: theme.accent)
        }
        JellyDecoderNote(text: "Titles off: no names under posters, and the rows close up as Netflix's do: bigger posters, close together, with small corners; Continue Watching shows just the picture.")
    }
}

// MARK: Playback

/// Playback: the next episode, watching, and the picture.
private struct JellyPlaybackGroups: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.autoplayKey) private var autoplay = true
    @AppStorage(JellyPrefs.countdownKey) private var countdown = 5
    @AppStorage(JellyPrefs.stillWatchingKey) private var stillWatching = 3
    @AppStorage(JellyPrefs.resumeKey) private var resume = true
    @AppStorage(JellyPrefs.ratingCardKey) private var ratingCard = true
    @AppStorage(JellyPrefs.timeModeKey) private var timeMode = "left"
    @AppStorage(JellyPrefs.batteryKey) private var battery = true
    @AppStorage(JellyPrefs.upscaleModeKey) private var upscale = JellyUpscale.initial

    private static let upscales = JellyUpscale.allCases.map { ($0.title, $0) }

    var body: some View {
        let accent = theme.accent
        Group {
            SettingsGroup(label: "Next episode") {
                JellySettingsRows.toggle("Play next episode", $autoplay, accent: accent)
                if autoplay {
                    SettingsDivider()
                    JellySettingsRows.choice("Countdown", $countdown, [("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15)])
                    SettingsDivider()
                    JellySettingsRows.choice("Ask if still watching", $stillWatching, JellySound.stillWatching)
                }
            }
            SettingsGroup(label: "Watching") {
                JellySettingsRows.toggle("Resume where you stopped", $resume, accent: accent)
                SettingsDivider()
                JellySettingsRows.toggle("Rating at the start", $ratingCard, accent: accent)
                SettingsDivider()
                JellySettingsRows.choice("Time shown", $timeMode, [("Time left", "left"), ("Total time", "total")])
                SettingsDivider()
                JellySettingsRows.toggle("Battery", $battery, accent: accent)
            }
            // Upscaling is AetherEngine's; mpv has its own (More → Super resolution while it plays).
            SettingsGroup(label: "Default decoder") {
                JellySettingsRows.choice("Upscaling", $upscale, Self.upscales)
            }
            JellyDecoderNote(text: "Auto and App only. On mpv: More → Super resolution and Smooth motion while it plays.")
        }
    }
}

// MARK: Skipping

/// Skipping: the intro, recap and credits buttons, where the times come from, and the skip length.
private struct JellySkippingGroups: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.skipIntroKey) private var skipIntro = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.skipRecapKey) private var skipRecap = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.skipCreditsKey) private var skipCredits = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.skipDelayKey) private var skipDelay = 0
    @AppStorage(JellyPrefs.introDBKey) private var introDB = true
    @AppStorage(JellyPrefs.skipSecondsKey) private var skipSeconds = 15

    private static let skipModes = JellySkipMode.allCases.map { ($0.rawValue, $0.rawValue) }

    var body: some View {
        Group {
            SettingsGroup(label: "Intros, recaps and credits") {
                JellySettingsRows.choice("Skip intros", $skipIntro, Self.skipModes)
                SettingsDivider()
                JellySettingsRows.choice("Skip recaps", $skipRecap, Self.skipModes)
                SettingsDivider()
                JellySettingsRows.choice("Skip credits", $skipCredits, Self.skipModes)
                if [skipIntro, skipRecap, skipCredits].contains(JellySkipMode.auto.rawValue) {
                    SettingsDivider()
                    JellySettingsRows.choice("Skip after", $skipDelay, [("At once", 0), ("2 seconds", 2), ("5 seconds", 5)])
                }
                SettingsDivider()
                JellySettingsRows.toggle("Intro times from IntroDB", $introDB, accent: theme.accent)
            }
            SettingsGroup(label: "Back and forward") {
                JellySettingsRows.choice("Skip by", $skipSeconds, [("10 seconds", 10), ("15 seconds", 15), ("30 seconds", 30)])
            }
        }
    }
}

// MARK: Preferences

/// The row on the JellySpace page: your audio language and aspect ratio at a glance.
private struct JellyPreferencesLink: View {
    @AppStorage(JellyPreferences.audioLanguageKey) private var audio = ""
    @AppStorage(JellyPrefs.fillKey) private var fill = JellyFill.fit.rawValue
    var body: some View {
        let language = JellySubtitleChoices.languages.first { $0.1 == audio && !audio.isEmpty }?.0
        JellySettingsLink(page: .preferences, value: [language, fill].compactMap { $0 }.joined(separator: " · "))
    }
}

/// Preferences: what a video starts with (audio and subtitle languages, the aspect ratio), and what
/// the player remembers of your choices. A video starts with what you picked in its show, then
/// these, then the file's own.
private struct JellyPreferencesGroups: View {
    var body: some View {
        Group {
            JellyAudioLanguageGroup()
            JellySubtitleLanguageGroup()
            JellyAspectGroup()
            JellyRememberGroup()
            JellyPrivacyGroup()
        }
    }
}

private struct JellyAudioLanguageGroup: View {
    @AppStorage(JellyPreferences.audioLanguageKey) private var language = ""
    @AppStorage(JellyPreferences.audioSecondKey) private var second = ""

    var body: some View {
        let languages = JellySubtitleChoices.languages
        SettingsGroup(label: "Audio") {
            JellySettingsRows.choice("Default audio language", $language, languages)
            if !language.isEmpty {
                SettingsDivider()
                JellySettingsRows.choice("Second choice", $second, languages.map { $0.1.isEmpty ? ("None", "") : $0 })
            }
        }
        JellyDecoderNote(text: "File's choice plays the track the file marks as its default.")
    }
}

/// Privacy: JellySpace behind Face ID, and how soon it locks again.
private struct JellyPrivacyGroup: View {
    @AppStorage(JellyPrefs.faceLockKey) private var on = false
    @AppStorage(JellyPrefs.faceLockAfterKey) private var after = 0
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        SettingsGroup(label: "Privacy") {
            JellySettingsRows.toggle("Face ID lock", Binding(get: { on }, set: { value in
                // Turned on here, it starts unlocked: it locks the next time the app is away.
                if value { JellyFaceLock.shared.turnedOn() }
                on = value
            }), accent: theme.accent)
            if on {
                SettingsDivider()
                JellySettingsRows.choice("Lock again", $after, JellyPrefs.faceLockAfterChoices)
            }
        }
        JellyDecoderNote(text: "Face ID (or your passcode) each time you open JellySpace, and again when you come back to the app after the time above. Hidden in the app switcher.")
    }
}

private struct JellyAspectGroup: View {
    @AppStorage(JellyPrefs.fillKey) private var fill = JellyFill.fit.rawValue
    @AppStorage(JellyPrefs.gpuZoomKey) private var gpuZoom = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private static let fills = JellyFill.allCases.map { ($0.rawValue, $0.rawValue) }

    var body: some View {
        SettingsGroup(label: "Picture") {
            JellySettingsRows.choice("Default aspect ratio", $fill, Self.fills)
            SettingsDivider()
            JellySettingsRows.toggle("GPU Enabled Zoom", $gpuZoom, accent: theme.accent)
        }
        JellyDecoderNote(text: "mpv only. On: Fill and Original use mpv's GPU output, with styled subtitles kept as made, but the picture goes black for a second as you switch. Off: Fill is instant on the cooler output, and the subtitles are drawn by the app (styled ones as plain text while filled). Original always uses the GPU.")
    }
}

private struct JellyRememberGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.rememberTracksKey) private var rememberTracks = true
    @AppStorage(JellyPreferences.perShowKey) private var perShow = true
    @AppStorage(JellyPreferences.fillPerShowKey) private var fillPerShow = false

    var body: some View {
        let accent = theme.accent
        SettingsGroup(label: "Remembering") {
            JellySettingsRows.toggle("Remember audio and subtitles", $rememberTracks, accent: accent)
            if rememberTracks {
                SettingsDivider()
                JellySettingsRows.toggle("Carry across a show's episodes", $perShow, accent: accent)
            }
            SettingsDivider()
            JellySettingsRows.toggle("Remember aspect ratio per show", $fillPerShow, accent: accent)
        }
        JellyDecoderNote(text: rememberTracks && perShow
            ? "Each show keeps its own: Japanese audio for an anime, English for a sitcom. Then your defaults, then the file's own."
            : rememberTracks ? "Your last choice anywhere, then your defaults, then the file's own." : "Your defaults, then the file's own.")
    }
}

// MARK: Subtitles

/// Subtitles: a preview, then the text, its edge, the box, where they sit, which ones a video starts
/// with, styled (anime) subtitles, and the delay. Each section holds only its own settings, so moving
/// a slider redraws that section and the preview, not the page.
private struct JellySubtitlesGroups: View {
    var body: some View {
        Group {
            JellySubtitlePreviewCard()
            JellySubtitleTextGroup()
            JellySubtitleEdgeGroup()
            JellySubtitleBoxGroup()
            JellySubtitlePositionGroup()
            JellySubtitleStyledGroup()
            JellySubtitleTimingGroup()
        }
    }
}

/// The look as it's set, over a picture, as the player draws it.
private struct JellySubtitlePreviewCard: View {
    @AppStorage(JellyPrefs.subtitleSizeKey) private var size = 1.0
    @AppStorage(JellyPrefs.subtitleColorKey) private var color = "white"
    @AppStorage(JellyPrefs.subtitleBoxKey) private var box = false
    @AppStorage(JellyPrefs.subtitleRaiseKey) private var raise = 0.0
    @AppStorage(JellySubtitlePrefs.fontKey) private var font = "system"
    @AppStorage(JellySubtitlePrefs.boldKey) private var bold = false
    @AppStorage(JellySubtitlePrefs.opacityKey) private var opacity = 1.0
    @AppStorage(JellySubtitlePrefs.outlineKey) private var outline = 2
    @AppStorage(JellySubtitlePrefs.outlineColorKey) private var outlineColor = "black"
    @AppStorage(JellySubtitlePrefs.shadowKey) private var shadow = 1
    @AppStorage(JellySubtitlePrefs.boxOpacityKey) private var boxOpacity = 0.6

    var body: some View {
        let look = JellySubtitleLook(size: size, font: font, bold: bold, color: color, opacity: opacity, outline: outline,
                                     outlineColor: outlineColor, shadow: shadow, box: box, boxOpacity: boxOpacity, raise: raise)
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.42, green: 0.62, blue: 0.78), Color(red: 0.26, green: 0.42, blue: 0.3)], startPoint: .top, endPoint: .bottom)
                Color(red: 0.17, green: 0.25, blue: 0.17).frame(height: height * 0.36)
                JellyPlainSubtitle(text: "That's the third one this week.", look: look, points: max(9, JellySubtitleLook.points(screenHeight: height, size: size)))
                    .padding(.horizontal, 12)
                    .padding(.bottom, height * 0.08 + height * raise)
            }
            .frame(width: proxy.size.width, height: height)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).frame(height: 22).background(.black.opacity(0.45), in: Capsule()).padding(10)
        }
        .animation(.easeOut(duration: 0.15), value: look)
        .accessibilityElement().accessibilityLabel("Subtitle preview")
    }
}

/// A row with a slider under its name, and what it's set to on the right.
private struct JellySliderRow: View {
    let title: String
    let shown: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Spacer(minLength: 8)
                Text(shown).font(.system(size: 14)).monospacedDigit().foregroundStyle(HomeStyle.secondary)
            }
            Slider(value: $value, in: range, step: step).tint(accent)
                .accessibilityLabel(title).accessibilityValue(shown)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
    }
}

/// A row of colour dots; the chosen one ringed.
private struct JellySwatchRow: View {
    let title: String
    let swatches: [JellySubtitleChoices.Swatch]
    @Binding var selected: String
    let accent: Color

    var body: some View {
        SettingsLine(title: title) {
            HStack(spacing: 10) {
                ForEach(swatches, id: \.key) { swatch in
                    Button { selected = swatch.key } label: {
                        Circle().fill(swatch.color).frame(width: 24, height: 24)
                            .overlay { Circle().strokeBorder(HomeStyle.primary.opacity(0.25), lineWidth: 0.5) }
                            .padding(3)
                            .overlay { if selected == swatch.key { Circle().strokeBorder(accent, lineWidth: 2) } }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(swatch.name).accessibilityAddTraits(selected == swatch.key ? .isSelected : [])
                }
            }
        }
    }
}

private struct JellySubtitleTextGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.subtitleSizeKey) private var size = 1.0
    @AppStorage(JellyPrefs.subtitleColorKey) private var color = "white"
    @AppStorage(JellySubtitlePrefs.fontKey) private var font = "system"
    @AppStorage(JellySubtitlePrefs.boldKey) private var bold = false
    @AppStorage(JellySubtitlePrefs.opacityKey) private var opacity = 1.0

    var body: some View {
        let accent = theme.accent
        SettingsGroup(label: "Text") {
            JellySliderRow(title: "Size", shown: "\(Int((size * 100).rounded()))%", value: $size, range: 0.5...2, step: 0.05, accent: accent)
            SettingsDivider()
            JellySettingsRows.choice("Font", $font, JellySubtitleChoices.fonts)
            SettingsDivider()
            JellySettingsRows.toggle("Bold", $bold, accent: accent)
            SettingsDivider()
            JellySwatchRow(title: "Colour", swatches: JellySubtitleChoices.colors, selected: $color, accent: accent)
            SettingsDivider()
            JellySliderRow(title: "Text opacity", shown: "\(Int((opacity * 100).rounded()))%", value: $opacity, range: 0.3...1, step: 0.05, accent: accent)
        }
    }
}

private struct JellySubtitleEdgeGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellySubtitlePrefs.outlineKey) private var outline = 2
    @AppStorage(JellySubtitlePrefs.outlineColorKey) private var outlineColor = "black"
    @AppStorage(JellySubtitlePrefs.shadowKey) private var shadow = 1

    var body: some View {
        let accent = theme.accent
        let names = JellySubtitleChoices.outlines
        let thickness = Binding<Double>(get: { Double(outline) }, set: { outline = Int($0.rounded()) })
        SettingsGroup(label: "Edge") {
            JellySliderRow(title: "Outline", shown: names[min(max(outline, 0), names.count - 1)], value: thickness,
                           range: 0...Double(names.count - 1), step: 1, accent: accent)
            SettingsDivider()
            JellySwatchRow(title: "Outline colour", swatches: JellySubtitleChoices.outlineColors, selected: $outlineColor, accent: accent)
            SettingsDivider()
            JellySettingsRows.choice("Shadow", $shadow, JellySubtitleChoices.shadows)
        }
    }
}

private struct JellySubtitleBoxGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.subtitleBoxKey) private var box = false
    @AppStorage(JellySubtitlePrefs.boxOpacityKey) private var boxOpacity = 0.6

    var body: some View {
        SettingsGroup(label: "Background") {
            JellySettingsRows.toggle("Box behind the text", $box, accent: theme.accent)
            if box {
                SettingsDivider()
                JellySliderRow(title: "Box opacity", shown: "\(Int((boxOpacity * 100).rounded()))%", value: $boxOpacity,
                               range: 0.1...1, step: 0.05, accent: theme.accent)
            }
        }
    }
}

private struct JellySubtitlePositionGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.subtitleRaiseKey) private var raise = 0.0
    @AppStorage(JellySubtitlePrefs.liftKey) private var lift = true

    var body: some View {
        SettingsGroup(label: "Position") {
            JellySliderRow(title: "Height from the bottom", shown: "\(Int((raise * 100).rounded()))%", value: $raise,
                           range: 0...0.25, step: 0.01, accent: theme.accent)
            SettingsDivider()
            JellySettingsRows.toggle("Move up when the controls show", $lift, accent: theme.accent)
        }
    }
}

private struct JellySubtitleLanguageGroup: View {
    @AppStorage(JellySubtitlePrefs.languageKey) private var language = ""
    @AppStorage(JellySubtitlePrefs.secondLanguageKey) private var second = ""
    @AppStorage(JellySubtitlePrefs.showKey) private var show = "always"
    @AppStorage(JellySubtitlePrefs.sdhKey) private var sdh = "avoid"

    var body: some View {
        let languages = JellySubtitleChoices.languages
        SettingsGroup(label: "Subtitles") {
            JellySettingsRows.choice("Show subtitles", $show, JellySubtitleChoices.show)
            if show != "off" {
                SettingsDivider()
                JellySettingsRows.choice("Default subtitle language", $language, languages)
                if !language.isEmpty {
                    SettingsDivider()
                    JellySettingsRows.choice("Second choice", $second, languages.map { $0.1.isEmpty ? ("None", "") : $0 })
                }
                if show == "always" {
                    SettingsDivider()
                    JellySettingsRows.choice("Hearing-impaired (SDH)", $sdh, JellySubtitleChoices.sdh)
                }
            }
        }
    }
}

private struct JellySubtitleStyledGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellySubtitlePrefs.styledKey) private var styled = "full"
    @AppStorage(JellySubtitlePrefs.styledSizeKey) private var styledSize = true

    var body: some View {
        SettingsGroup(label: "Styled subtitles (anime)") {
            JellySettingsRows.choice("Draw them", $styled, JellySubtitleChoices.styled)
            if styled == "full" {
                SettingsDivider()
                JellySettingsRows.toggle("Apply my size to them", $styledSize, accent: theme.accent)
            }
        }
        Text(styled == "full" ? "As made: their own fonts, colours and places, as Infuse shows them." : "Mine: as plain text, in the look set above.")
            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, -14)
    }
}

private struct JellySubtitleTimingGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellySubtitlePrefs.rememberDelayKey) private var rememberDelay = true
    @AppStorage(JellySubtitlePrefs.delayStepKey) private var delayStep = 0.1

    var body: some View {
        SettingsGroup(label: "Timing") {
            JellySettingsRows.toggle("Remember the delay for each show", $rememberDelay, accent: theme.accent)
            SettingsDivider()
            JellySettingsRows.choice("Delay step", $delayStep, JellySubtitleChoices.delaySteps)
        }
    }
}

// MARK: Sound

private struct JellySoundGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.dialogueKey) private var dialogue = 0
    @AppStorage(JellyPrefs.nightKey) private var night = false
    @AppStorage(JellyPrefs.boostKey) private var boost = 0

    var body: some View {
        SettingsGroup(label: "Sound") {
            JellySettingsRows.choice("Dialogue boost", $dialogue, JellySound.dialogue)
            SettingsDivider()
            JellySettingsRows.toggle("Night mode", $night, accent: theme.accent)
            SettingsDivider()
            JellySettingsRows.choice("Volume boost", $boost, JellySound.boost)
        }
        JellyDecoderNote(text: "Auto and App only: mpv plays the sound as the file has it.")
    }
}

/// Under a group that only one decoder uses: which, and where the other's own is.
private struct JellyDecoderNote: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, -14)
    }
}

// MARK: Gestures, music and the diary

private struct JellyGesturesGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.swipeSeekKey) private var swipeSeek = true
    @AppStorage(JellyPrefs.swipeLevelsKey) private var swipeLevels = true
    @AppStorage(JellyPrefs.holdKey) private var hold = true

    var body: some View {
        SettingsGroup(label: "Gestures") {
            JellySettingsRows.toggle("Swipe to move through", $swipeSeek, accent: theme.accent)
            SettingsDivider()
            JellySettingsRows.toggle("Brightness and volume swipes", $swipeLevels, accent: theme.accent)
            SettingsDivider()
            JellySettingsRows.toggle("Hold for 2x", $hold, accent: theme.accent)
        }
    }
}

private struct JellyMusicDiaryGroups: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.lrclibKey) private var lrclib = true
    @AppStorage(JellyPrefs.diaryKey) private var diary = true

    var body: some View {
        Group {
            SettingsGroup(label: "Music") {
                JellySettingsRows.toggle("Lyrics from LRCLIB", $lrclib, accent: theme.accent)
            }
            SettingsGroup(label: "Diary") {
                JellySettingsRows.toggle("Mark watched in diary", $diary, accent: theme.accent)
            }
        }
    }
}

// MARK: Requests (Jellyseerr)

/// Its own view: a letter typed in the address redraws these few rows, not the page.
private struct JellyRequestsGroup: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.seerrAddressKey) private var seerrAddress = ""
    /// Read from the Keychain once the group is up.
    @State private var seerrKey = ""
    @State private var seerrNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(label: "Requests") {
                TextField("Jellyseerr address", text: $seerrAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .font(.system(size: 15)).padding(.horizontal, 16).frame(minHeight: 48).accessibilityIdentifier("jellyspace-seerr-address")
                SettingsDivider()
                SecureField("API key", text: $seerrKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(size: 15)).padding(.horizontal, 16).frame(minHeight: 48).accessibilityIdentifier("jellyspace-seerr-key")
                SettingsDivider()
                JellySettingsRows.button("Save", accent: theme.accent) { Task { await saveSeerr() } }
            }
            if let seerrNotice { Text(seerrNotice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
        }
        .task { if seerrKey.isEmpty { seerrKey = JellySecrets.read("seerr-key") ?? "" } }
    }
    private func saveSeerr() async {
        JellySecrets.write("seerr-key", seerrKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let seerr = JellySpace.seerr else { seerrNotice = seerrAddress.isEmpty ? "Removed" : "Check the address"; return }
        seerrNotice = "Checking…"
        do {
            try await seerr.check()
            seerrNotice = "Connected"
        } catch {
            seerrNotice = error.localizedDescription
        }
    }
}

// MARK: Storage

private struct JellyStorageGroup: View {
    @Binding var notice: String?
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        SettingsGroup(label: "Storage") {
            Button {
                Task { await JellyfinPosterCache.shared.removeAll() }
                notice = "Picture cache cleared"
            } label: {
                Text("Clear picture cache").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-clear-cache")
        }
    }
}

// MARK: Signing in

/// Sign in as a Jellyfin user: Quick Connect shows a code to approve in another signed-in Jellyfin
/// app (Settings → Quick Connect there); the password way asks for the name and password.
struct JellySignInSheet: View {
    enum Mode: String, Identifiable {
        case quick, password
        var id: String { rawValue }
    }
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var code: String?
    @State private var name = ""
    @State private var password = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .quick {
                    if let code {
                        Text(code).font(.system(size: 44, weight: .bold, design: .monospaced)).tracking(6)
                            .foregroundStyle(HomeStyle.primary).frame(maxWidth: .infinity).accessibilityIdentifier("jellyspace-quick-code")
                        Text("Enter this code under Quick Connect in another Jellyfin app you're signed in to.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        ProgressView().frame(maxWidth: .infinity)
                    } else if failure == nil {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                    }
                } else {
                    TextField("Name", text: $name).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 14).frame(minHeight: 48).diaryPanel(padding: 0, radius: 12)
                    SecureField("Password", text: $password).textContentType(.password)
                        .padding(.horizontal, 14).frame(minHeight: 48).diaryPanel(padding: 0, radius: 12)
                    Button { Task { await signInWithPassword() } } label: {
                        Group { if working { ProgressView().tint(WatchStyle.ink) } else { Text("Sign in") } }
                            .font(.system(size: 16, weight: .bold)).foregroundStyle(WatchStyle.ink)
                            .frame(maxWidth: .infinity, minHeight: 50).background(WatchStyle.fill, in: Capsule())
                    }.buttonStyle(.plain).disabled(name.isEmpty || working).accessibilityIdentifier("jellyspace-sign-in")
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .padding(20)
            .diaryScreenBackground()
            .navigationTitle(mode == .quick ? "Quick Connect" : "Sign in").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { if mode == .quick { await quickConnect() } }
    }

    private func signInWithPassword() async {
        guard let base = JellyfinSettings.address else { failure = "Connect Jellyfin first."; return }
        working = true; failure = nil
        defer { working = false }
        do {
            JellyAccount.save(try await JellyAuth.signIn(base, name: name.trimmingCharacters(in: .whitespaces), password: password))
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
    /// Shows the code, then checks every few seconds (for up to five minutes) whether it was approved.
    private func quickConnect() async {
        guard let base = JellyfinSettings.address else { failure = "Connect Jellyfin first."; return }
        guard await JellyAuth.quickConnectEnabled(base) else { failure = "Quick Connect is turned off on this server."; return }
        do {
            let started = try await JellyAuth.startQuickConnect(base)
            code = started.Code
            for _ in 0..<100 {
                try await Task.sleep(for: .seconds(3))
                if await JellyAuth.approved(base, secret: started.Secret) {
                    JellyAccount.save(try await JellyAuth.finishQuickConnect(base, secret: started.Secret))
                    dismiss()
                    return
                }
            }
            failure = "The code ran out. Try again."
            code = nil
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}
