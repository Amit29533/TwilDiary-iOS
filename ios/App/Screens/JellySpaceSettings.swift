import SwiftUI
import Security
import TwilDiaryCore

// MARK: Preferences

/// JellySpace's settings, kept in UserDefaults (read by @AppStorage in the pages and the player).
enum JellyPrefs {
    static let rowsKey = "jellyspace.home.rows"
    static let hiddenRowsKey = "jellyspace.home.hiddenRows"
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
    static let diaryKey = "jellyspace.diary"
    static let rememberTracksKey = "jellyspace.rememberTracks"
    static let swipeSeekKey = "jellyspace.gesture.seek"
    static let swipeLevelsKey = "jellyspace.gesture.levels"
    static let holdKey = "jellyspace.gesture.hold"
    static let seerrAddressKey = "jellyspace.seerr.address"
    static let fillKey = "jellyspace.fill"
    static let upscaleKey = "jellyspace.upscale"
    static let upscaleModeKey = "jellyspace.upscaleMode"
    static let skipDelayKey = "jellyspace.skip.delay"
    static let batteryKey = "jellyspace.battery"
    static let timeModeKey = "jellyspace.timeMode"
    static let subtitleLanguageKey = "jellyspace.subtitleSearchLanguage"
    static let lrclibKey = "jellyspace.lrclib"
}

/// The home's rows, in the order you set; any you turned off are left out.
enum JellyHomeRow: String, CaseIterable, Identifiable {
    case hero, resume, media, libraries, forYou, favourites, collections
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hero: "Top poster"
        case .media: "My Media"
        case .resume: "Continue Watching"
        case .favourites: "Favourites"
        case .libraries: "Library rows"
        case .forYou: "For you"
        case .collections: "Collections"
        }
    }
    static func order(_ raw: String) -> [JellyHomeRow] {
        // The top poster always leads (it runs under the bar): only the rows below it are ordered.
        let saved = raw.split(separator: ",").compactMap { JellyHomeRow(rawValue: String($0)) }.filter { $0 != .hero }
        return saved + allCases.filter { $0 != .hero && !saved.contains($0) }
    }
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

enum JellySkipMode: String, CaseIterable {
    case off = "Off", button = "Button", auto = "Automatic"
}

/// Libraries, folders, shows and films you hid from JellySpace (id → name, so they can be listed).
enum JellyHidden {
    static func decode(_ raw: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8))) ?? [:]
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
    }
}

// MARK: The settings page

/// Settings → JellySpace: who you watch as, the home's rows, what's hidden, posters, the player,
/// gestures, the diary, Jellyseerr requests and the picture cache.
struct JellySpaceSettingsView: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(JellyPrefs.rowsKey) private var rowsRaw = ""
    @AppStorage(JellyPrefs.hiddenRowsKey) private var hiddenRowsRaw = ""
    @AppStorage(JellyPrefs.hiddenKey) private var hiddenRaw = "{}"
    @AppStorage(JellyPrefs.countsKey) private var counts = true
    @AppStorage(JellyPrefs.ticksKey) private var ticks = true
    @AppStorage(JellyPrefs.captionsKey) private var captions = true
    @AppStorage(JellyPrefs.skipIntroKey) private var skipIntro = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.skipRecapKey) private var skipRecap = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.skipCreditsKey) private var skipCredits = JellySkipMode.button.rawValue
    @AppStorage(JellyPrefs.introDBKey) private var introDB = true
    @AppStorage(JellyPrefs.skipDelayKey) private var skipDelay = 0
    @AppStorage(JellyPrefs.batteryKey) private var battery = true
    @AppStorage(JellyPrefs.timeModeKey) private var timeMode = "left"
    @AppStorage(JellyPrefs.lrclibKey) private var lrclib = true
    @AppStorage(JellyPrefs.skipSecondsKey) private var skipSeconds = 15
    @AppStorage(JellyPrefs.autoplayKey) private var autoplay = true
    @AppStorage(JellyPrefs.countdownKey) private var countdown = 5
    @AppStorage(JellyPrefs.resumeKey) private var resume = true
    @AppStorage(JellyPrefs.diaryKey) private var diary = true
    @AppStorage(JellyPrefs.rememberTracksKey) private var rememberTracks = true
    @AppStorage(JellyPrefs.swipeSeekKey) private var swipeSeek = true
    @AppStorage(JellyPrefs.swipeLevelsKey) private var swipeLevels = true
    @AppStorage(JellyPrefs.holdKey) private var hold = true
    @AppStorage(JellyPrefs.fillKey) private var fill = JellyFill.fit.rawValue
    @AppStorage(JellyPrefs.upscaleModeKey) private var upscale = JellyUpscale.initial
    @AppStorage(JellyPrefs.seerrAddressKey) private var seerrAddress = ""
    @State private var seerrKey = JellySecrets.read("seerr-key") ?? ""
    @State private var seerrNotice: String?
    @State private var libraries: [JellyfinLibrary] = []
    @State private var profiles: [JellyfinClient.Profile] = []
    @State private var watchingAs: String?
    @State private var signedIn = JellyAccount.userName
    @State private var signIn: JellySignInSheet.Mode?
    @State private var notice: String?

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 22) {
                account
                home
                hidden
                SettingsGroup(label: "Posters") {
                    toggleLine("Unwatched counts", $counts)
                    SettingsDivider()
                    toggleLine("Watched ticks", $ticks)
                    SettingsDivider()
                    toggleLine("Titles", $captions)
                }
                player
                SettingsGroup(label: "Gestures") {
                    toggleLine("Swipe to move through", $swipeSeek)
                    SettingsDivider()
                    toggleLine("Brightness and volume swipes", $swipeLevels)
                    SettingsDivider()
                    toggleLine("Hold for 2x", $hold)
                }
                SettingsGroup(label: "Music") {
                    toggleLine("Lyrics from LRCLIB", $lrclib)
                }
                SettingsGroup(label: "Diary") {
                    toggleLine("Mark watched in diary", $diary)
                }
                requests
                SettingsGroup(label: "Storage") {
                    Button {
                        Task { await JellyfinPosterCache.shared.removeAll() }
                        notice = "Picture cache cleared"
                    } label: {
                        Text("Clear picture cache").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("jellyspace-clear-cache")
                }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("JellySpace")
        .task { await load() }
        .sheet(item: $signIn, onDismiss: { signedIn = JellyAccount.userName; Task { await load() } }) { JellySignInSheet(mode: $0) }
    }

    // MARK: Account

    private var account: some View {
        SettingsGroup(label: "Account") {
            if let signedIn {
                SettingsLine(title: signedIn) {
                    Button("Sign out") {
                        JellyAccount.signOut()
                        self.signedIn = nil
                        Task { await load() }
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
                        } label: { menuLabel(profiles.first { $0.Id == watchingAs }?.Name ?? "Choose") }
                            .accessibilityIdentifier("jellyspace-watching-as")
                    }
                    SettingsDivider()
                }
                buttonLine("Sign in with Quick Connect") { signIn = .quick }
                SettingsDivider()
                buttonLine("Sign in with password") { signIn = .password }
            }
        }
    }

    // MARK: Home rows and what's hidden

    private var home: some View {
        let order = JellyHomeRow.order(rowsRaw), off = JellyHomeRow.hidden(hiddenRowsRaw)
        return SettingsGroup(label: "Home") {
            toggleLine(JellyHomeRow.hero.title, Binding(get: { !off.contains(.hero) }, set: { on in
                var next = off
                if on { next.remove(.hero) } else { next.insert(.hero) }
                hiddenRowsRaw = next.map(\.rawValue).sorted().joined(separator: ",")
            }))
            ForEach(Array(order.enumerated()), id: \.element) { position, row in
                SettingsDivider()
                HStack(spacing: 10) {
                    Text(row.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    Spacer(minLength: 8)
                    moveButton("chevron.up", label: "Move \(row.title) up", disabled: position == 0) { move(row, by: -1, in: order) }
                    moveButton("chevron.down", label: "Move \(row.title) down", disabled: position == order.count - 1) { move(row, by: 1, in: order) }
                    Toggle("", isOn: Binding(get: { !off.contains(row) }, set: { on in
                        var next = off
                        if on { next.remove(row) } else { next.insert(row) }
                        hiddenRowsRaw = next.map(\.rawValue).sorted().joined(separator: ",")
                    })).labelsHidden().tint(theme.accent).accessibilityLabel(row.title)
                }.padding(.horizontal, 16).frame(minHeight: 50)
            }
        }
    }
    private func move(_ row: JellyHomeRow, by step: Int, in order: [JellyHomeRow]) {
        guard let at = order.firstIndex(of: row), order.indices.contains(at + step) else { return }
        var next = order
        next.swapAt(at, at + step)
        rowsRaw = next.map(\.rawValue).joined(separator: ",")
    }
    private func moveButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.secondary)
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.07), in: Circle())
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1).accessibilityLabel(label)
    }

    private var hidden: some View {
        let items = JellyHidden.decode(hiddenRaw)
        let libraryIDs = Set(libraries.map(\.id))
        let others = items.filter { !libraryIDs.contains($0.key) }.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        return SettingsGroup(label: "Libraries") {
            if libraries.isEmpty && others.isEmpty {
                SettingsLine(title: "No libraries") { EmptyView() }
            }
            ForEach(Array(libraries.enumerated()), id: \.element.id) { position, library in
                if position > 0 { SettingsDivider() }
                toggleLine(library.name, Binding(get: { items[library.id] == nil }, set: { on in
                    if on { JellyHidden.show(library.id) } else { JellyHidden.hide(library.id, name: library.name) }
                    hiddenRaw = UserDefaults.standard.string(forKey: JellyPrefs.hiddenKey) ?? "{}"
                }))
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

    // MARK: Player

    private var player: some View {
        SettingsGroup(label: "Player") {
            choiceLine("Skip intros", $skipIntro, JellySkipMode.allCases.map { ($0.rawValue, $0.rawValue) })
            SettingsDivider()
            choiceLine("Skip recaps", $skipRecap, JellySkipMode.allCases.map { ($0.rawValue, $0.rawValue) })
            SettingsDivider()
            choiceLine("Skip credits", $skipCredits, JellySkipMode.allCases.map { ($0.rawValue, $0.rawValue) })
            SettingsDivider()
            if [skipIntro, skipRecap, skipCredits].contains(JellySkipMode.auto.rawValue) {
                SettingsDivider()
                choiceLine("Skip after", $skipDelay, [("At once", 0), ("2 seconds", 2), ("5 seconds", 5)])
            }
            SettingsDivider()
            toggleLine("Intro times from IntroDB", $introDB)
            SettingsDivider()
            choiceLine("Skip by", $skipSeconds, [("10 seconds", 10), ("15 seconds", 15), ("30 seconds", 30)])
            SettingsDivider()
            toggleLine("Play next episode", $autoplay)
            if autoplay {
                SettingsDivider()
                choiceLine("Countdown", $countdown, [("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15)])
            }
            SettingsDivider()
            toggleLine("Resume where you stopped", $resume)
            SettingsDivider()
            choiceLine("Time shown", $timeMode, [("Time left", "left"), ("Total time", "total")])
            SettingsDivider()
            toggleLine("Battery", $battery)
            SettingsDivider()
            choiceLine("Picture", $fill, JellyFill.allCases.map { ($0.rawValue, $0.rawValue) })
            SettingsDivider()
            choiceLine("Upscaling", $upscale, JellyUpscale.allCases.map { ($0.title, $0) })
            SettingsDivider()
            toggleLine("Remember audio and subtitles", $rememberTracks)
        }
    }

    // MARK: Requests (Jellyseerr)

    private var requests: some View {
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
                buttonLine("Save") { Task { await saveSeerr() } }
            }
            if let seerrNotice { Text(seerrNotice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4) }
        }
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

    // MARK: Rows

    private func toggleLine(_ title: String, _ value: Binding<Bool>) -> some View {
        SettingsLine(title: title) { Toggle("", isOn: value).labelsHidden().tint(theme.accent).accessibilityLabel(title) }
    }
    private func choiceLine<Value: Hashable>(_ title: String, _ value: Binding<Value>, _ options: [(String, Value)]) -> some View {
        SettingsLine(title: title) {
            Menu {
                Picker(title, selection: value) { ForEach(options, id: \.1) { Text($0.0).tag($0.1) } }
            } label: { menuLabel(options.first { $0.1 == value.wrappedValue }?.0 ?? "") }
                .accessibilityLabel(title)
        }
    }
    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 15))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
        }.foregroundStyle(HomeStyle.secondary)
    }
    private func buttonLine(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(.horizontal, 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func load() async {
        guard let client = JellySpace.client else { return }
        libraries = (try? await client.libraries()) ?? []
        watchingAs = await JellyfinUser.id(client)
        profiles = JellyAccount.token == nil ? ((try? await client.profiles()) ?? []) : []
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
