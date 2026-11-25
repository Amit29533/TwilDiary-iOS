import SwiftUI
import AuthenticationServices
import TwilDiaryCore

/// Profile → Connections. On top, where your diary lives: Trakt, MDBList and WeTrakr in one list.
/// The ticked one is your main tracker (the diary comes from it; edits go to it, and also to the
/// others you're signed in to). Each row opens that service's page; ⋯ has the quick actions.
/// Then the services kept in step that can't be main (Simkl). Below: how this iPhone reaches your
/// server, and the services that use a key.
struct ConnectionsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage(MainTrackerView.key) private var mainTracker = MainTracker.trakt.rawValue
    @State private var aniList = AniListSyncAccount.shared
    @State private var aniListSync = AniListSync.shared
    /// Your server switched on (here, in Sync & backup, or by a Cloudflare sign-in).
    @AppStorage(ExtrasStorage.serverKey) private var server = false
    /// Trakt's real state (Not connected, Reconnect…), from your server.
    @State private var traktDirect = TraktDirectStore.shared
    @State private var others = TrackerPreviewStore.shared
    @State private var profiles = AccountProfiles.shared
    @State private var matching: MainTracker?
    @State private var note: String?
    @State private var signingIn: MainTracker?
    @State private var signingInAniList = false
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private var main: MainTracker { MainTracker(main: mainTracker) ?? .trakt }

    var body: some View {
        EdgeToEdgeScroll {
            // Design (board 3): WHERE YOUR DIARY LIVES, YOUR DIARY and KEYS, each a card of rows.
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(label: "Where your diary lives") {
                        ForEach(Array(MainTracker.offered.enumerated()), id: \.element) { index, tracker in
                            if index > 0 { divider }
                            trackerRow(tracker)
                        }
                    }
                    if let progress = activity {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary) }.padding(.horizontal, 4)
                    } else if let note = note ?? lastResult {
                        SettingsFootnote(text: note).accessibilityIdentifier("trackers-note")
                    }
                }
                SettingsGroup(label: "Also kept in sync") {
                    ForEach(Array(MainTracker.alsoSynced.enumerated()), id: \.element) { index, tracker in
                        if index > 0 { divider }
                        trackerRow(tracker)
                    }
                }
                SettingsGroup(label: "Anime sync") {
                    aniListRow
                }
                SettingsGroup(label: "Your server") {
                    // No sign-in (owner's choice): the app reaches your server with its own key.
                    if ThemeStore.current.native {
                        // Native: a settings row with the system switch, the same height as the rows below.
                        HStack(spacing: 12) {
                            SettingsTile(symbol: "server.rack")
                            Toggle(isOn: $server) { SettingsRowTitle("Your server", "").frame(maxWidth: .infinity, alignment: .leading) }
                        }.settingsRowFrame().accessibilityIdentifier("connections-server")
                    } else {
                    HStack(spacing: 14) {
                        SettingsTile(symbol: "server.rack")
                        Text("Your server").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        Toggle("", isOn: $server).labelsHidden().tint(theme.accent)
                    }.padding(.horizontal, 15).frame(minHeight: 64).accessibilityIdentifier("connections-server")
                    }
                    // The browsing preview shows them too (its UI tests open them).
                    if server || store.isPreview {
                        divider
                        row(SettingsTile(symbol: "externaldrive.badge.timemachine"), "Backups", "",
                            value: nil, destination: .backups, id: "connections-backups")
                        divider
                        row(BrandLogo(service: .cloudflare, size: 38), "Cloudflare usage", "",
                            value: nil, destination: .cloudflare, id: "settings-cloudflare")
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SettingsGroup(label: "Keys") {
                        row(BrandLogo(service: .tmdb, size: 38), "TMDB", "", value: nil, destination: .tmdb, id: "settings-tmdb")
                        divider
                        row(BrandLogo(service: .tvdb, size: 38), "TheTVDB", "", value: nil, destination: .tvdb, id: "settings-tvdb")
                        divider
                        NavigationLink(value: AppDestination.apis) {
                            if ThemeStore.current.native {
                                rowLabel(SettingsTile(symbol: "key.fill"), "All keys", "", value: nil)
                            } else {
                                Text("All keys").font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 15).contentShape(Rectangle())
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-apis")
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().diaryPageNavigation("Connections")
            .alert(matching.map { "Make \($0.name) match the diary?" } ?? "", isPresented: Binding(get: { matching != nil }, set: { if !$0 { matching = nil } })) {
                if let tracker = matching {
                    Button("Send to \(tracker.name)") { Task { await match(tracker) } }
                    Button("Cancel", role: .cancel) { matching = nil }
                }
            } message: {
                if let tracker = matching, let plan = writePlan(tracker) {
                    Text(plan.summary.map { "• " + $0 }.joined(separator: "\n") + "\n\nNothing is removed from your \(tracker.name) history.")
                }
            }
            .onChange(of: server) { _, on in ExtrasStorage.switched(on, store: store) }
            .task { SimklAccount.shared.adopt(store) }
    }

    // MARK: Trackers

    /// Signed in (whether or not sync is on).
    private func connected(_ tracker: MainTracker) -> Bool {
        switch tracker {
        case .trakt: store.traktSignedInOnPhone
        case .mdblist: store.providerSettings.mdblist.isAuthenticated
        case .wetrakr: store.providerSettings.wetrakr.isAuthenticated
        case .simkl: store.providerSettings.simkl.isAuthenticated
        }
    }
    /// Signed in and syncing (Trakt always syncs once signed in).
    private func syncing(_ tracker: MainTracker) -> Bool {
        tracker == .trakt ? connected(.trakt) : connected(tracker) && store.providerSettings.config(for: tracker.provider).enabled
    }
    /// "Connected", "Not connected", "Reconnect"… (Trakt's from your server).
    private func badge(_ tracker: MainTracker) -> String {
        switch tracker {
        case .trakt:
            store.traktSignedInOnPhone ? "Connected" : "Not connected"
        case .mdblist: connected(.mdblist) ? "Connected" : "Not connected"
        case .wetrakr: connected(.wetrakr) ? "Connected" : "Not connected"
        case .simkl: connected(.simkl) ? "Connected" : "Not connected"
        }
    }
    private func account(_ tracker: MainTracker) -> String? {
        switch tracker {
        case .trakt: store.traktSignedInOnPhone ? store.providerSettings.trakt.username : nil
        case .mdblist: store.providerSettings.mdblist.username
        case .wetrakr: store.providerSettings.wetrakr.username
        case .simkl: store.providerSettings.simkl.username
        }
    }
    private func checkedAt(_ tracker: MainTracker) -> Date? {
        let stamp = tracker == .trakt ? traktDirect.library?.fetchedAt : others.libraries[tracker]?.fetchedAt
        return stamp.flatMap { try? Date($0, strategy: .iso8601) }
    }
    private func writePlan(_ tracker: MainTracker) -> TraktWritePlan? {
        tracker == .trakt ? traktDirect.plan : others.plans[tracker]
    }
    private var activity: String? {
        if traktDirect.running { return "Reading Trakt…" }
        if let running = others.running { return "Reading \(running.name)…" }
        return traktDirect.writeProgress ?? others.writeProgress
    }
    private var lastResult: String? {
        if let error = traktDirect.error { return error }
        for tracker in MainTracker.others { if let error = others.errors[tracker] { return "\(tracker.name): " + error } }
        return traktDirect.writeResult ?? others.writeResults.values.first
    }

    private func trackerRow(_ tracker: MainTracker) -> some View {
        let isMain = tracker == main, on = connected(tracker)
        let destination: AppDestination = switch tracker { case .trakt: .trakt; case .mdblist: .mdblist; case .wetrakr: .wetrakr; case .simkl: .simkl }
        let profile = on ? profiles.account(tracker) : nil
        let checked = checkedAt(tracker).map { $0.formatted(.relative(presentation: .named)) }
        let sync = syncing(tracker)
        let detail = on ? [profile?.name ?? account(tracker), sync ? checked : "Sync off"].compactMap { $0 }.joined(separator: " · ") : ""
        // A connection that needs attention says so (in amber), instead of looking healthy.
        let status = badge(tracker), problem = ["Reconnect", "Unavailable"].contains(status)
        let native = ThemeStore.current.native
        return HStack(spacing: 4) {
            NavigationLink(value: destination) {
                HStack(spacing: 14) {
                    // As Cinopsys: your picture on the service, its logo on the corner.
                    avatar(profile?.avatar, on: on)
                        .overlay(alignment: .bottomTrailing) {
                            BrandLogo(service: tracker.brand, size: native ? 18 : 20)
                                .overlay(RoundedRectangle(cornerRadius: 20 * 0.225).strokeBorder(native ? Color(uiColor: .secondarySystemBackground) : Color(themed: "#111115"), lineWidth: 2))
                                .offset(x: 4, y: 4)
                        }.opacity(on || isMain ? 1 : 0.6)
                    VStack(alignment: .leading, spacing: native ? 1 : 3) {
                        HStack(spacing: 6) {
                            // Native: a list row's 17 pt title and 13 pt line, as the other settings rows.
                            Text(tracker.name).font(.app(size: native ? 17 : 16, weight: native ? .semibold : .bold)).foregroundStyle(HomeStyle.primary)
                            if let plan = profile?.plan { Text("· " + plan).font(.app(size: native ? 17 : 15)).foregroundStyle(HomeStyle.secondary) }
                            if isMain {
                                Image(systemName: "checkmark.seal.fill").font(.app(size: 15)).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, theme.accent).accessibilityHidden(true)
                            }
                        }.lineLimit(1)
                        HStack(spacing: 6) {
                            if on && !problem {
                                Circle().fill(native ? Color(uiColor: sync ? .systemGreen : .systemGray) : sync ? Color(themed: "#7fe0b5") : Color(themed: "#8e8e9c"))
                                    .frame(width: 6, height: 6)
                            }
                            Text(on && !detail.isEmpty && !problem ? detail : status).font(.app(size: native ? 13 : 12))
                                .foregroundStyle(problem ? (native ? Color(uiColor: .systemOrange) : Color(themed: "#f5c26b")) : HomeStyle.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, native ? 16 : 15).padding(.vertical, native ? 10 : 12).frame(minHeight: native ? 64 : nil).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .task(id: on) { if on { await profiles.refresh(tracker, store: store) } }
                // VoiceOver hears the status even when the row shows the account instead.
                .accessibilityLabel([tracker.name, isMain ? "Main" : nil, status, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier("settings-" + tracker.rawValue)
            // Not signed in: one tap opens the service's own sign-in page right here.
            if !on || problem, ServiceSignIn.supportsSheet(tracker.provider) {
                if native {
                    // Native: the same small button as every other row's ("Run", "Check").
                    Button(signingIn == tracker ? "Opening…" : problem ? "Reconnect" : "Sign in") { Task { await signIn(tracker) } }
                        .buttonStyle(SettingsPillButtonStyle()).lineLimit(1).disabled(signingIn != nil)
                        .accessibilityIdentifier(tracker.rawValue + "-quick-sign-in")
                } else {
                Button { Task { await signIn(tracker) } } label: {
                    Group {
                        if signingIn == tracker { ProgressView().controlSize(.small) }
                        else { Text(problem ? "Reconnect" : "Sign in").font(.app(size: 13, weight: .semibold)).lineLimit(1) }
                    }.padding(.horizontal, 14).frame(height: 32).foregroundStyle(HomeStyle.chipText).background(HomeStyle.chip, in: Capsule())
                }.buttonStyle(.plain).disabled(signingIn != nil).accessibilityIdentifier(tracker.rawValue + "-quick-sign-in")
                }
            }
            Menu {
                if !isMain, MainTracker.offered.contains(tracker) { Button("Make main tracker", systemImage: "checkmark.circle") { makeMain(tracker) }.disabled(!on) }
                Button("Check now", systemImage: "arrow.clockwise") { Task { await check(tracker) } }.disabled(!on)
                // Connected through your server: move the Trakt sign-in onto this iPhone in one tap.
                if tracker == .trakt, on, !store.traktSignedInOnPhone {
                    Button("Sign in on this iPhone", systemImage: "iphone") { Task { await signIn(.trakt) } }
                }
                if tracker == .trakt, store.traktSignedInOnPhone {
                    Button("Sign out of Trakt", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await store.signOutTraktOnPhone(); note = "Signed out of Trakt on this iPhone." }
                    }
                }
                if let plan = writePlan(tracker), !plan.isEmpty {
                    Button("Make \(tracker.name) match the diary", systemImage: "arrow.triangle.2.circlepath") { matching = tracker }
                }
            } label: {
                Image(systemName: "ellipsis").font(.app(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("\(tracker.name) actions").accessibilityIdentifier(tracker.rawValue + "-actions").padding(.trailing, 6)
        }.background(isMain && !native ? Color(themed: "#1d1934") : .clear)
    }

    /// AniList, as the trackers' rows: your picture with its logo on the corner, @name and when it
    /// last sent, a Sign in button while signed out, and ⋯ (Check now, Make AniList match).
    private var aniListRow: some View {
        let on = aniList.signedIn, sync = on && aniList.saving
        let native = ThemeStore.current.native
        let sent = aniListSync.lastSentAt.map { $0.formatted(.relative(presentation: .named)) }
        let detail = on ? [aniList.username.map { "@" + $0 }, sync ? sent : "Sync off"].compactMap { $0 }.joined(separator: " · ") : "Not signed in"
        return HStack(spacing: 4) {
            NavigationLink(value: AppDestination.anilist) {
                HStack(spacing: 14) {
                    avatar(on ? aniList.avatar : nil, on: on)
                        .overlay(alignment: .bottomTrailing) {
                            BrandLogo(service: .anilist, size: native ? 18 : 20)
                                .overlay(RoundedRectangle(cornerRadius: 20 * 0.225).strokeBorder(native ? Color(uiColor: .secondarySystemBackground) : Color(themed: "#111115"), lineWidth: 2))
                                .offset(x: 4, y: 4)
                        }.opacity(on ? 1 : 0.6)
                    VStack(alignment: .leading, spacing: native ? 1 : 3) {
                        Text("AniList").font(.app(size: native ? 17 : 16, weight: native ? .semibold : .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        HStack(spacing: 6) {
                            if on {
                                Circle().fill(native ? Color(uiColor: sync ? .systemGreen : .systemGray) : sync ? Color(themed: "#7fe0b5") : Color(themed: "#8e8e9c"))
                                    .frame(width: 6, height: 6)
                            }
                            Text(detail).font(.app(size: native ? 13 : 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, native ? 16 : 15).padding(.vertical, native ? 10 : 12).frame(minHeight: native ? 64 : nil).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .task(id: on) { if on { await aniList.refreshProfile() } }
                .accessibilityLabel(["AniList", detail].joined(separator: ", ")).accessibilityIdentifier("settings-anilist")
            if !on {
                Button(signingInAniList ? "Opening…" : "Sign in") {
                    Task {
                        signingInAniList = true; defer { signingInAniList = false }
                        do { if try await aniList.signIn(using: webAuthenticationSession) { note = "Signed in to AniList" + (aniList.username.map { " as @" + $0 } ?? "") + "." } }
                        catch { note = FriendlyError.message(error) }
                    }
                }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1).disabled(signingInAniList).accessibilityIdentifier("anilist-quick-sign-in")
            }
            Menu {
                Button("Check now", systemImage: "arrow.clockwise") { Task { await aniListSync.check(store: store) } }.disabled(!on)
                if let comparison = aniListSync.comparison, !comparison.keysToSend.isEmpty {
                    Button("Make AniList match the diary", systemImage: "arrow.triangle.2.circlepath") { aniListSync.makeMatch(store: store) }.disabled(!aniList.canSend)
                }
            } label: {
                Image(systemName: "ellipsis").font(.app(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("AniList actions").accessibilityIdentifier("anilist-actions").padding(.trailing, 6)
        }
    }

    /// Your picture on the service, or a plain person while it's unknown or you're not signed in.
    private func avatar(_ path: String?, on: Bool) -> some View {
        ZStack {
            Circle().fill(ThemeStore.current.native ? Color(uiColor: .systemGray4) : Color(themed: "#2a2a31"))
            Image(systemName: "person.fill").font(.app(size: 20)).foregroundStyle(ThemeStore.current.native ? Color.white : Color(themed: "#8e8e9c"))
            // Account pictures live on each service's own host (not TMDB's), so they load directly.
            if let path, let url = URL(string: path), url.scheme == "https" {
                AsyncImage(url: url, transaction: Transaction(animation: .smooth(duration: 0.25))) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                }.clipShape(Circle())
            }
        }.frame(width: ThemeStore.current.native ? 42 : 46, height: ThemeStore.current.native ? 42 : 46)
    }
    private func signIn(_ tracker: MainTracker) async {
        signingIn = tracker; note = nil
        defer { signingIn = nil }
        do {
            if case .signedIn = try await ServiceSignIn.run(tracker.provider, store: store, using: webAuthenticationSession) {
                await profiles.refresh(tracker, store: store, force: true)
                note = "Signed in to \(tracker.name)" + (profiles.account(tracker)?.name.map { " as " + $0 } ?? "") + "."
            }
        } catch { note = FriendlyError.message(error) }
    }
    /// The main tracker holds the diary: the diary is shown from it, and edits go to it.
    private func makeMain(_ tracker: MainTracker) {
        mainTracker = tracker.rawValue
        note = "\(tracker.name) holds your diary now."
        guard !store.isPreview else { return }
        store.keepDiary(on: tracker)
    }
    private func check(_ tracker: MainTracker) async {
        note = nil
        if tracker == .trakt { await traktDirect.check(store: store) } else { await others.check(tracker, store: store) }
    }
    private func match(_ tracker: MainTracker) async {
        matching = nil; note = nil
        if tracker == .trakt { await traktDirect.makeTraktMatch(store: store) } else { await others.makeMatch(tracker, store: store) }
    }

    // MARK: Rows

    private var divider: some View { SettingsDivider() }
    private func row<Leading: View>(_ leading: Leading, _ title: String, _ subtitle: String, value: String?, destination: AppDestination, id: String) -> some View {
        NavigationLink(value: destination) { rowLabel(leading, title, subtitle, value: value) }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
    @ViewBuilder private func rowLabel<Leading: View>(_ leading: Leading, _ title: String, _ subtitle: String, value: String?) -> some View {
        if ThemeStore.current.native {
            // Native: as iOS Settings, the title alone with its value and chevron, 52 pt like every row.
            HStack(spacing: 12) {
                leading.frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7))
                Text(title).font(.app(size: 17)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Spacer(minLength: 4)
                if let value { Text(value).font(.app(size: 17)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                SettingsChevron()
            }.settingsRowFrame().contentShape(Rectangle())
        } else {
            HStack(spacing: 14) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2) }
                }
                Spacer(minLength: 4)
                if let value { Text(value).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1) }
                SettingsChevron()
            }.padding(.horizontal, 15).frame(minHeight: 64).contentShape(Rectangle())
        }
    }
}
