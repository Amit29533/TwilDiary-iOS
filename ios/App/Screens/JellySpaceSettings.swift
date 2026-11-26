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
    /// Whether Jellyseerr answered when its address and key were last saved.
    static let seerrOnKey = "jellyspace.seerr.on"
    static let fillKey = "jellyspace.fill"
    /// JellySpace behind Face ID (Preferences → Privacy), and the seconds away before it locks again.
    static let faceLockKey = "jellyspace.faceLock"
    static let faceLockAfterKey = "jellyspace.faceLock.after"
    static let faceLockAfterChoices: [(String, Int)] = [("Immediately", 0), ("After 1 minute", 60), ("After 5 minutes", 300), ("After 15 minutes", 900)]
    /// mpv's Fill and Original on its GPU output (on: styled subtitles kept, a second of black as it
    /// switches); off, Fill zooms at once on the AVFoundation output and the app draws the subtitles.
    static let gpuZoomKey = "jellyspace.mpv.gpuZoom"
    /// The engine a video opens on unless you moved it to the other one: "auto", "app" or "mpv".
    static let engineKey = "jellyspace.engine.default"
    static let mpvSmoothKey = "jellyspace.mpvSmoothRate"
    static let mpvSuperResolutionKey = "jellyspace.mpvSuperResolution"
    static let mpvCompositeKey = "jellyspace.mpv.compositeOSD"
    static let upscaleKey = "jellyspace.upscale"
    static let upscaleModeKey = "jellyspace.upscaleMode"
    static let skipDelayKey = "jellyspace.skip.delay"
    static let batteryKey = "jellyspace.battery"
    /// The Cast and AirPlay buttons at the top of the player (both shown unless turned off).
    static let castButtonKey = "jellyspace.button.cast"
    /// Pictures over the bar while seeking: Jellyfin's trickplay where the server has it, else
    /// AetherEngine's own.
    static let seekPreviewsKey = "jellyspace.seekPreviews"
    static let airPlayButtonKey = "jellyspace.button.airplay"
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
    case hero, resume, media, genres, tags, top10, libraries, gems, tonight, forYou, themes, random, favourites, collections
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hero: "Top poster"
        case .media: "My Media"
        case .resume: "Continue Watching"
        case .favourites: "Favourites"
        case .libraries: "Library rows"
        case .genres: "Genres"
        case .tags: "Tags"
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
    /// Always also upscales 1080p videos (AetherEngine's Lanczos); Auto leaves them as they are. (It was
    /// a switch of its own, Upscale 1080p: owner's request to fold it into Always.)
    var upscalesFullHD: Bool { self == .always }
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
        // The server's side too: the token stayed good there.
        if let base = JellyfinSettings.address, let token { Task.detached { await JellyAuth.signOut(base, token: token) } }
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
    case preferences, home, libraries, engines, playback, skipping, subtitles, gestures, requests, musicDiary, server
    var title: String {
        switch self {
        case .server: "Server"
        case .preferences: "Preferences"
        case .home: "Home"
        case .libraries: "Libraries"
        case .playback: "Playback"
        case .skipping: "Skipping"
        case .subtitles: "Subtitles"
        case .engines: "Engines"
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
        case .engines: "cpu.fill"
        case .gestures: "hand.draw.fill"
        case .requests: "tray.and.arrow.down.fill"
        case .musicDiary: "music.note"
        case .server: "server.rack"
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
        case .engines: .mint
        case .gestures: .teal
        case .requests: .purple
        case .musicDiary: .green
        case .server: .purple
        }
    }
}

/// The server's libraries, kept while the app runs so the Home and Libraries pages open with them.
@MainActor enum JellySettingsLibraries {
    static var cached: [JellyfinLibrary] = []
    static func load() async -> [JellyfinLibrary] {
        guard let client = JellySpace.client else { return cached }
        let user = await JellyfinUser.id(client)
        if let found = try? await client.libraries(user: user) { cached = found }
        return cached
    }
}

/// Settings → JellySpace, as iOS Settings is: your account at the top, then a row for each page in
/// three sections (JellySpace, Player, More), and the picture cache at the foot.
struct JellySpaceSettingsView: View {
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @AppStorage(JellyPrefs.seerrAddressKey) private var seerrAddress = ""
    @AppStorage(JellyPrefs.seerrOnKey) private var seerrOn = true
    @AppStorage(JellyPrefs.engineKey) private var engine = JellyDecoder.auto.rawValue
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
                    JellySettingsLink(page: .engines, value: JellyEnginesGroups.names[engine] ?? "Auto")
                    SettingsDivider()
                    JellySettingsLink(page: .playback)
                    SettingsDivider()
                    JellySettingsLink(page: .skipping)
                    SettingsDivider()
                    JellySettingsLink(page: .subtitles)
                    SettingsDivider()
                    JellySettingsLink(page: .gestures)
                }
                SettingsGroup(label: "More") {
                    JellySettingsLink(page: .requests, value: seerrAddress.isEmpty ? "Off" : seerrOn ? "On" : "Not connected")
                    SettingsDivider()
                    JellySettingsLink(page: .musicDiary)
                }
                SettingsGroup(label: "Administration") {
                    JellySettingsLink(page: .server)
                }
                JellyStorageGroup(notice: $notice)
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("JellySpace")
        // Behind the lock as JellySpace's own pages are: these name what you've hidden, and turn it off.
        .jellyFaceLock()
        .jellyPage()
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
                Text(page.title).font(.app(size: ThemeStore.current.native ? 17 : 15, weight: ThemeStore.current.native ? .regular : .semibold))
                    .foregroundStyle(HomeStyle.primary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let value { Text(value).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
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
            Image(systemName: page.symbol).font(.app(size: 16, weight: .medium)).foregroundStyle(HomeStyle.chipText)
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
        Group {
            // Home: a native list of its own (rows dragged into order; see JellyHomeSettingsPage).
            if page == .home {
                JellyHomeSettingsPage(libraries: shown)
            } else {
                pageScroll(hiddenItems)
            }
        }
        .jellyFaceLock()
        .jellyPage()
        .task {
            guard page == .home || page == .libraries else { return }
            let found = await JellySettingsLibraries.load()
            if found != libraries { libraries = found }
        }
    }
    private func pageScroll(_ hiddenItems: [String: String]) -> some View {
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 22) {
                switch page {
                case .home:
                    EmptyView()
                case .libraries:
                    JellyLibrariesGroup(libraries: libraries, hiddenItems: hiddenItems, hiddenRaw: $hiddenRaw)
                case .preferences: JellyPreferencesGroups()
                case .playback: JellyPlaybackGroups()
                case .skipping: JellySkippingGroups()
                case .subtitles: JellySubtitlesGroups()
                case .engines: JellyEnginesGroups()
                case .gestures: JellyGesturesGroup()
                case .requests: JellyRequestsGroup()
                case .musicDiary: JellyMusicDiaryGroups()
                case .server: JellyServerGroups()
                }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation(page.title)
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
            Text(text).font(.app(size: 15))
            Image(systemName: "chevron.up.chevron.down").font(.app(size: 11, weight: .semibold))
        }.foregroundStyle(HomeStyle.secondary)
    }
    static func button(_ title: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.app(size: 16, weight: .semibold)).foregroundStyle(accent)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
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
                    }.font(.app(size: 15, weight: .semibold)).foregroundStyle(theme.accent).accessibilityIdentifier("jellyspace-sign-out")
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

// MARK: What's hidden (Home's rows and My Media: JellyHomeSettings.swift)

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
                    }.font(.app(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                }
            }
        }
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
    @AppStorage(JellyPrefs.seekPreviewsKey) private var seekPreviews = true
    @AppStorage(JellyPrefs.castButtonKey) private var castButton = true
    @AppStorage(JellyPrefs.airPlayButtonKey) private var airPlayButton = true

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
                JellySettingsRows.toggle("Seek previews", $seekPreviews, accent: accent)
                SettingsDivider()
                JellySettingsRows.toggle("Battery", $battery, accent: accent)
            }
            SettingsGroup(label: "Buttons") {
                JellySettingsRows.toggle("Cast", $castButton, accent: accent)
                SettingsDivider()
                JellySettingsRows.toggle("AirPlay", $airPlayButton, accent: accent)
            }
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
    @State private var needsPasscode = false

    var body: some View {
        SettingsGroup(label: "Privacy") {
            JellySettingsRows.toggle("Face ID lock", Binding(get: { on }, set: { value in
                // Not on a phone without a passcode: the lock would have nothing to check against.
                if value, !JellyFaceLock.available { needsPasscode = true; return }
                // Turned on here, it starts unlocked: it locks the next time the app is away.
                if value { JellyFaceLock.shared.turnedOn(); on = true; return }
                Task { if await JellyFaceLock.shared.confirm("Turn off the Face ID lock") { on = false } }
            }), accent: theme.accent)
            if on {
                SettingsDivider()
                JellySettingsRows.choice("Lock again", $after, JellyPrefs.faceLockAfterChoices)
            }
        }
        JellyDecoderNote(text: "Face ID (or your passcode) each time you open JellySpace, and again when you come back to the app after the time above. Hidden in the app switcher.")
            .alert("Set a passcode first", isPresented: $needsPasscode) {
                Button("OK", role: .cancel) {}
            } message: { Text("The lock uses Face ID or your iPhone’s passcode. Turn on a passcode in iOS Settings → Face ID & Passcode, then try again.") }
    }
}

private struct JellyAspectGroup: View {
    @AppStorage(JellyPrefs.fillKey) private var fill = JellyFill.fit.rawValue
    private static let fills = JellyFill.allCases.map { ($0.rawValue, $0.rawValue) }

    var body: some View {
        SettingsGroup(label: "Picture") {
            JellySettingsRows.choice("Default aspect ratio", $fill, Self.fills)
        }
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
            JellySubtitlePictureGroup()
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
            Text("Preview").font(.app(size: 11, weight: .semibold)).foregroundStyle(.white)
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
                Text(title).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Spacer(minLength: 8)
                Text(shown).font(.app(size: 14)).monospacedDigit().foregroundStyle(HomeStyle.secondary)
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

/// Picture subtitles (PGS, DVD): as made, or read on the phone and drawn as text in the look set above.
private struct JellySubtitlePictureGroup: View {
    @AppStorage(JellySubtitlePrefs.picturesKey) private var pictures = "full"
    var body: some View {
        SettingsGroup(label: "Picture subtitles (PGS)") {
            JellySettingsRows.choice("Draw them", $pictures, JellySubtitleChoices.styled)
        }
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

// MARK: Engines

/// Engines: the one a video opens on, AetherEngine's upscaling and sound, and mpv's picture options.
struct JellyEnginesGroups: View {
    static let names = ["auto": "Auto", "app": "AetherEngine", "mpv": "mpv"]
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.engineKey) private var engine = JellyDecoder.auto.rawValue
    @AppStorage(JellyPrefs.upscaleModeKey) private var upscale = JellyUpscale.initial
    @AppStorage(JellyPrefs.dialogueKey) private var dialogue = 0
    @AppStorage(JellyPrefs.nightKey) private var night = false
    @AppStorage(JellyPrefs.boostKey) private var boost = 0
    @AppStorage(JellyPrefs.mpvSuperResolutionKey) private var superResolution = "off"
    @AppStorage(JellyPrefs.mpvSmoothKey) private var smooth = 0
    @AppStorage(JellyPrefs.gpuZoomKey) private var gpuZoom = false
    @AppStorage(JellyPrefs.mpvCompositeKey) private var composite = JellyMPV.compositesByDefault
    @State private var moved = JellyMPVChoice.count
    private static let upscales = JellyUpscale.allCases.map { ($0.title, $0) }
    private static let smoothRates: [(String, Int)] = [("Off", 0), ("60 Hz", 60), ("120 Hz", 120)]

    var body: some View {
        let accent = theme.accent
        Group {
            SettingsGroup(label: "Default engine") {
                Picker("Default engine", selection: $engine) {
                    Text("Auto").tag(JellyDecoder.auto.rawValue)
                    Text("AetherEngine").tag(JellyDecoder.app.rawValue)
                    Text("mpv").tag(JellyDecoder.mpv.rawValue)
                }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 12)
                .accessibilityIdentifier("jellyspace-default-engine")
            }
            JellyDecoderNote(text: "Auto: AetherEngine with the phone's hardware decoder where it can. AetherEngine: its own decoder for everything. A video you moved to the other engine in the player stays on it.")
            SettingsGroup(label: "AetherEngine") {
                JellySettingsRows.choice("Upscaling", $upscale, Self.upscales)
                SettingsDivider()
                JellySettingsRows.choice("Dialogue boost", $dialogue, JellySound.dialogue)
                SettingsDivider()
                JellySettingsRows.toggle("Night mode", $night, accent: accent)
                SettingsDivider()
                JellySettingsRows.choice("Volume boost", $boost, JellySound.boost)
            }
            JellyDecoderNote(text: "Upscaling uses Apple's super resolution and MetalFX on video below 1080p. mpv plays the sound as the file has it.")
            SettingsGroup(label: "mpv") {
                JellySettingsRows.choice("Super resolution", $superResolution, JellyPlayerView.superResolutions)
                SettingsDivider()
                JellySettingsRows.choice("Smooth motion", $smooth, Self.smoothRates)
                SettingsDivider()
                JellySettingsRows.toggle("GPU Enabled Zoom", $gpuZoom, accent: accent)
                SettingsDivider()
                JellySettingsRows.toggle("Subtitles in the picture", $composite, accent: accent)
            }
            JellyDecoderNote(text: "Super resolution and smooth motion pause while the phone is hot or in Low Power Mode. GPU Enabled Zoom: Fill keeps styled subtitles as made, with a second of black as you switch; off (as it starts), Fill is instant and cooler. Original always uses the GPU. Subtitles in the picture: mpv draws them into each frame; off, they're drawn over it.")
            SettingsGroup(label: "Videos") {
                Button(role: .destructive) {
                    JellyMPVChoice.forgetAll()
                    moved = 0
                } label: {
                    Text(moved == 0 ? "No videos set to an engine of their own" : "Forget videos set to an engine (\(moved))")
                        .font(.app(size: 15, weight: .semibold)).foregroundStyle(moved == 0 ? HomeStyle.secondary : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(minHeight: 50).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(moved == 0).accessibilityIdentifier("jellyspace-forget-engines")
            }
        }
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
    @AppStorage(JellyPrefs.seerrAddressKey) private var savedAddress = ""
    @AppStorage(JellyPrefs.seerrOnKey) private var seerrOn = true
    /// The address as typed: kept only when saved, with its key. Kept as it was typed, a search meanwhile
    /// sent the key to whatever the half-typed address named.
    @State private var seerrAddress = ""
    /// Read from the Keychain once the group is up.
    @State private var seerrKey = ""
    @State private var seerrNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(label: "Requests") {
                TextField("Jellyseerr address", text: $seerrAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .font(.app(size: 15)).padding(.horizontal, 16).frame(minHeight: 48).accessibilityIdentifier("jellyspace-seerr-address")
                SettingsDivider()
                SecureField("API key", text: $seerrKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.app(size: 15)).padding(.horizontal, 16).frame(minHeight: 48).accessibilityIdentifier("jellyspace-seerr-key")
                SettingsDivider()
                JellySettingsRows.button("Save", accent: theme.accent) { Task { await saveSeerr() } }
            }
            if let seerrNotice { Text(seerrNotice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
        }
        .task {
            if seerrAddress.isEmpty { seerrAddress = savedAddress }
            if seerrKey.isEmpty { seerrKey = JellySecrets.read("seerr-key") ?? "" }
        }
    }
    private func saveSeerr() async {
        let address = seerrAddress.trimmingCharacters(in: .whitespacesAndNewlines), key = seerrKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // No address: removed, its key with it (which stayed in the Keychain).
        guard !address.isEmpty else {
            JellySecrets.write("seerr-key", nil)
            savedAddress = ""; seerrKey = ""; seerrOn = true
            seerrNotice = "Removed"
            return
        }
        guard JellyfinSettings.normalized(address) != nil else { seerrNotice = "Check the address"; return }
        guard !key.isEmpty else { seerrNotice = "Enter the API key"; return }
        savedAddress = address
        JellySecrets.write("seerr-key", key)
        guard let seerr = JellySpace.seerr else { seerrNotice = "Check the address"; return }
        seerrNotice = "Checking…"
        do {
            try await seerr.check()
            seerrOn = true
            seerrNotice = "Connected"
        } catch {
            seerrOn = false
            seerrNotice = FriendlyError.message(error)
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
                Text("Clear picture cache").font(.app(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
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
                        Text(code).font(.app(size: 44, weight: .bold, design: .monospaced)).tracking(6)
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
                            .font(.app(size: 16, weight: .bold)).foregroundStyle(WatchStyle.ink)
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
            failure = FriendlyError.message(error)
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
            failure = FriendlyError.message(error)
        }
    }
}
