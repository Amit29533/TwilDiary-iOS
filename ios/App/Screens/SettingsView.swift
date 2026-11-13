import SwiftUI
import AuthenticationServices
import TwilDiaryCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @AppStorage(AppTab.launchKey) private var launchTab = AppTab.glance
    @AppStorage(AniListMostWatched.userKey) private var anilistUser = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmSignOut = false
    @State private var confirmDiscardPending = false
    @State private var reviewProviderConflict = false
    @State private var summary: TraktController?
    @State private var showExport = false
    @State private var showImport = false
    @State private var backupNotice: String?
    @State private var exportDocument = DiaryJSONDocument(data: Data())
    var body: some View {
        VStack(spacing: 0) {
            EdgeToEdgeScroll {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(name: "Profile").padding(.horizontal, -16).padding(.bottom, -14)
                    NavigationLink(value: AppDestination.profile) {
                        HStack(spacing: 14) {
                            PersonalAvatar().frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PersonalProfile.shared.name).font(.system(size: 18, weight: .bold)).foregroundStyle(HomeStyle.primary)
                                Text(accountHandle).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                            }
                            Spacer(); chevron
                        }.padding(15).modifier(SettingsCard()).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-personal-profile")
                    diaryCard
                    if let warning = store.cacheWarning {
                        Text(warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4).accessibilityIdentifier("settings-cache-warning")
                    }
                    if let notice = store.providerVaultNotice, !store.phoneOnly {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Review provider settings sync") { reviewProviderConflict = true }.font(.subheadline)
                                .disabled(store.providerVaultBusy).accessibilityIdentifier("settings-review-vault")
                        }.padding(14).background(theme.field, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if store.pendingDiaryEdits > 0 {
                        settingsSection("PENDING SYNC") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(store.outboxNotice ?? "Saved on this device · \(store.pendingDiaryEdits) pending sync")
                                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                ForEach(store.outbox.pending(for: .cloudflare)) { entry in
                                    Text(store.title(entry.mutation.titleId)?.name ?? "Removed title").font(.subheadline)
                                }
                                HStack {
                                    Button("Retry sync") { Task { await store.flushOutbox() } }.disabled(store.replayingOutbox || store.busy)
                                    Spacer()
                                    Button("Discard pending edits", role: .destructive) { confirmDiscardPending = true }.disabled(store.replayingOutbox || store.busy)
                                }.font(.subheadline)
                            }.padding(14)
                        }.accessibilityIdentifier("settings-pending-sync")
                    }
                    settingsSection("LIBRARY") {
                        HStack(spacing: 12) {
                            tile("star.fill", .purple)
                            VStack(alignment: .leading, spacing: 2) { Text("Public ratings").font(.system(size: 15, weight: .semibold)); Text("Community scores, not your rating").font(.system(size: 12)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Menu { Picker("Library ratings", selection: $ratingSource) { ForEach(PublicRatingSource.allCases) { Text($0.label).tag($0) } } }
                                label: { FilterPill(label: ratingSource.label) }.fixedSize().accessibilityLabel("Library ratings").accessibilityValue(ratingSource.label).accessibilityIdentifier("settings-rating-source")
                        }.padding(.horizontal, 15).frame(minHeight: 64)
                        divider
                        NavigationLink(value: AppDestination.files) { settingsRow("externaldrive.fill", .green, "Files & drives", value: driveCount == 0 ? nil : String(driveCount), disclosure: true) }.accessibilityIdentifier("settings-files")
                        divider
                        NavigationLink(value: AppDestination.trash) { settingsRow("trash.fill", .red, "Trash", value: trashCount == 0 ? "Empty" : String(trashCount), disclosure: true) }
                    }
                    settingsSection("TRACKING") {
                        HStack(spacing: 12) {
                            tile("eye.slash.fill", .indigo)
                            Toggle(isOn: $hideSpoilers) {
                                VStack(alignment: .leading, spacing: 2) { Text("Hide spoilers").font(.system(size: 15, weight: .semibold)); Text("Names and stills until watched").font(.system(size: 12)).foregroundStyle(.secondary) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.tint(theme.accent)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).frame(minHeight: 64)
                        divider
                        NavigationLink(value: AppDestination.history) { settingsRow("clock.arrow.circlepath", .blue, "Watch history", subtitle: "Recently watched, dates and filters", disclosure: true) }.accessibilityIdentifier("settings-history")
                        divider
                        NavigationLink(value: AppDestination.calendar) { settingsRow("calendar", .indigo, "Airing calendar", subtitle: "Upcoming and catch-up episodes", disclosure: true) }.accessibilityIdentifier("settings-calendar")
                    }
                    settingsSection("APPEARANCE") {
                        NavigationLink(value: AppDestination.appearance) {
                            VStack(alignment: .leading, spacing: 8) {
                                settingsRow("paintpalette.fill", .pink, "Theme", value: theme.name, disclosure: true, padded: false)
                                // A glance at every theme; choosing one happens on the Theme page.
                                HStack(spacing: 12) {
                                    ForEach(DiaryTheme.allCases) { item in
                                        Circle().fill(item.accent).frame(width: 26, height: 26)
                                            .overlay { if item == theme { Circle().strokeBorder(HomeStyle.primary, lineWidth: 2).padding(-3) } }
                                    }
                                }.padding(.leading, 52).padding(.bottom, 6).accessibilityHidden(true)
                            }.padding(.horizontal, 15).padding(.vertical, 12)
                        }.accessibilityIdentifier("settings-theme")
                        divider
                        HStack(spacing: 12) {
                            tile("rectangle.portrait.and.arrow.forward", .orange)
                            VStack(alignment: .leading, spacing: 2) { Text("Opens on").font(.system(size: 15, weight: .semibold)); Text("The screen TwilDiary starts on").font(.system(size: 12)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Menu { Picker("Opens on", selection: $launchTab) { ForEach(AppTab.allCases, id: \.self) { Text($0.label).tag($0) } } }
                                label: { FilterPill(label: launchTab.label) }.fixedSize().accessibilityLabel("Opens on").accessibilityValue(launchTab.label).accessibilityIdentifier("settings-launch-tab")
                        }.padding(.horizontal, 15).frame(minHeight: 64)
                        divider
                        settingsRow("circle.dotted.circle", .teal, "Reduce motion", value: reduceMotion ? "On · device" : "Follows device")
                        divider
                        settingsRow("globe.asia.australia.fill", .cyan, "Time zone", value: TimeZone.current.identifier.replacingOccurrences(of: "_", with: " "))
                        divider
                        NavigationLink(value: AppDestination.languageRegion) { settingsRow("character.bubble.fill", .blue, "Language & region", value: languageRegionSummary, disclosure: true) }
                            .accessibilityIdentifier("settings-language-region")
                    }
                    settingsSection("CONNECTIONS AND DATA") {
                        NavigationLink(value: AppDestination.connections) {
                            settingsRow("link", .purple, "Connections", subtitle: "Trakt, MDBList, WeTrakr, AniList and more", value: connectionsSummary, disclosure: true)
                        }.accessibilityIdentifier("settings-connections")
                        divider
                        Button { exportDiary() } label: { settingsRow("square.and.arrow.up.fill", .mint, "Export diary", subtitle: "Titles, progress and notes", disclosure: true) }
                        divider
                        Button { showImport = true } label: { settingsRow("square.and.arrow.down.fill", .mint, "Import diary", subtitle: "Letterboxd, IMDb, MAL and more", value: backupNotice, disclosure: true) }.accessibilityIdentifier("settings-import-diary")
                        divider
                        NavigationLink(value: AppDestination.syncBackup) { settingsRow("archivebox.fill", .teal, "Sync & backup", subtitle: "Background sync and backups", disclosure: true) }.accessibilityIdentifier("settings-backups")
                        divider
                        NavigationLink(value: AppDestination.notifications) { settingsRow("bell.badge.fill", .red, "Notifications", subtitle: "New episodes and releases", disclosure: true) }.accessibilityIdentifier("settings-notifications")
                    }
                    VStack(spacing: 10) {
                        NavigationLink(value: AppDestination.about) {
                            Text("\(Text("TwilDiary \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0") · ").foregroundStyle(HomeStyle.secondary))\(Text("About and licenses").fontWeight(.semibold).foregroundStyle(HomeStyle.chipText))")
                                .font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityIdentifier("settings-about")
                        Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).multilineTextAlignment(.center)
                        Button { confirmSignOut = true } label: {
                            Text("Sign out").font(.system(size: 15, weight: .bold)).foregroundStyle(Color(webHex: "#ffb3c0"))
                                .frame(maxWidth: .infinity, minHeight: 52).background(HomeStyle.round, in: Capsule())
                        }.disabled(store.busy).padding(.top, 8).accessibilityIdentifier("settings-sign-out")
                    }.frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.top, 8)
                }.buttonStyle(.plain).toggleStyle(SettingsToggleStyle()).padding(.horizontal, 16).padding(.bottom, 24)
            }.refreshable { await store.refresh(); await summary?.refresh() }
        }
        .alert(store.pendingDiaryEdits + TraktDirectStore.shared.pending.count > 0 ? "Sign out? Pending edits on this device, including any still waiting for Trakt, will be removed. Your hosted diary stays saved." : "Sign out on this device? Your hosted diary stays saved.", isPresented: $confirmSignOut) { Button("Sign out", role: .destructive) { store.signOut() }; Button("Cancel", role: .cancel) {} }
        .alert("Which provider settings should this device keep? Only your pending fields will change.", isPresented: $reviewProviderConflict) {
            Button("Keep this device’s settings") { Task { await store.resolveProviderVaultConflict(keepDevice: true) } }
            Button("Use saved online settings") { Task { await store.resolveProviderVaultConflict(keepDevice: false) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Discard all pending edits on this device? The latest hosted diary will be loaded first.", isPresented: $confirmDiscardPending) {
            Button("Discard pending edits", role: .destructive) { Task { await store.discardPendingEdits() } }
            Button("Cancel", role: .cancel) {}
        }
            .task(id: store.sessionRevision) {
                summary = TraktController(service: makeTraktService(store: store))
                await summary?.refresh()
                await store.pullProviderVaultFromServer()
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await summary?.refresh() } } }
            .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json, defaultFilename: "TwilDiary-\(DiaryDate.day(store.now))") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.json, .commaSeparatedText]) { result in
                switch result {
                case .success(let url):
                    Task {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let data = try Data(contentsOf: url)
                            if store.phoneOnly, url.pathExtension.lowercased() == "json" {
                                // No server: a TwilDiary backup goes where the diary lives, its phone extras onto the phone.
                                struct Copy: Decodable { let phone: PhoneExtras.Backup? }
                                let archive = try DiaryExport.decoded(from: data)
                                let phone = (try? JSONDecoder().decode(Copy.self, from: data))?.phone
                                _ = try await ServerBackups.restore(archive, phone: phone, store: store)
                                backupNotice = "Restored"
                                return
                            }
                            let summary = try await store.importDiaryArchive(data)
                            backupNotice = "Imported \(summary.titles)"
                        } catch {
                            store.error = error.localizedDescription
                        }
                    }
                case .failure(let error):
                    store.error = error.localizedDescription
                }
            }
    }
    /// With no server sign-in, the diary is the service's: reading it, sending your edits, or synced.
    private var phoneDiaryState: String {
        if store.onThisPhone { return "On this phone" }
        guard let service = store.diaryService else { return "Synced" }
        let reading = service == .trakt ? TraktDirectStore.shared.running : TrackerPreviewStore.shared.running == service
        let sending = service == .trakt ? TraktDirectStore.shared.pending.count : TrackerPreviewStore.shared.pending[service]?.count ?? 0
        return reading ? "Refreshing…" : sending > 0 ? "Sending \(sending)…" : "Synced"
    }
    /// "Your diary": its state, what it holds, when it was last updated and what it's
    /// connected to. Tapping refreshes it from the server.
    private var diaryCard: some View {
        let titles = store.activeTitles.count, watches = store.activeEvents.count
        let state = store.phoneOnly ? phoneDiaryState : store.loading ? "Refreshing…" : store.pendingDiaryEdits > 0 ? "Pending sync" : store.busy ? "Saving…" : store.quotaBlockedUntil != nil ? "Paused" : store.showingCachedSnapshot ? "Saved copy" : "Synced"
        let tint: Color = state == "Synced" || state == "On this phone" ? Color(webHex: "#7fe0b5") : state == "Paused" || state == "Saved copy" ? .orange : HomeStyle.dateChipText
        return VStack(alignment: .leading, spacing: 0) {
            Button { Task { if store.phoneOnly { await store.readDiaryServiceIfDue(olderThan: 0) } else { await store.refresh() } } } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Your diary").font(.system(size: 18, weight: .bold))
                        Spacer(minLength: 8)
                        HStack(spacing: 5) { Circle().fill(tint).frame(width: 6, height: 6); Text(state) }
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(tint).padding(.horizontal, 10).frame(height: 22)
                            .background(state == "Synced" || state == "On this phone" ? Color(webHex: "#1b2b25") : tint.opacity(0.14), in: Capsule())
                    }
                    HStack(spacing: 8) {
                        statTile(titles, "titles")
                        statTile(watches, "watches")
                        statTile(driveCount, driveCount == 1 ? "drive" : "drives")
                    }
                    if let reset = store.quotaBlockedUntil {
                        Text("Database allowance resumes " + reset.formatted(date: .abbreviated, time: .shortened) + ". Tap to check again.").font(.caption).foregroundStyle(.secondary)
                    }
                }.foregroundStyle(HomeStyle.primary).padding(17).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.disabled(store.loading || store.busy).accessibilityIdentifier("settings-refresh-diary").accessibilityHint("Refresh your diary from the server")
            divider
            NavigationLink(value: AppDestination.statistics) {
                settingsRow("chart.bar.fill", .purple, "Statistics", subtitle: "Watch time and trends", disclosure: true)
            }.accessibilityIdentifier("settings-statistics")
        }.modifier(SettingsCard())
    }
    private func statTile(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.system(size: 20, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 59, alignment: .leading)
            .background(HomeStyle.round, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
    }
    /// "@amit29533": your AniList name, else your Trakt account.
    private var accountHandle: String {
        if !anilistUser.isEmpty { return "@" + anilistUser }
        if let name = store.traktController.status?.username, !name.isEmpty { return "@" + name }
        return "Profile"
    }
    private var languageRegionSummary: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let language = Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
        let region = UserDefaults.standard.string(forKey: "streamingRegion") ?? Locale.current.region?.identifier ?? "US"
        return language + " · " + LanguageRegionView.regionName(region)
    }
    private var trashCount: Int { store.phoneOnly ? PhoneTrash.shared.titles.count : store.workspace.titles.reduce(0) { $0 + ($1.deletedAt == nil ? 0 : 1) } }
    private var driveCount: Int { DiskSummary.make(store.workspace.locations).count }
    /// Trakt's state in a word for its row; the full sync controls live on the Trakt page.
    /// "Trakt · 2 connected": the main tracker and how many services are signed in.
    private var connectionsSummary: String {
        let count = [store.traktController.status?.connected == true, store.providerSettings.mdblist.isAuthenticated].filter { $0 }.count
        return count > 0 ? "\(count) on" : "Off"
    }
    private func settingsSection<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        // Design: a 13 pt bold #9a9aa8 label, 16 pt above a #0e0e12 card (radius 22).
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.secondary).frame(height: 20).padding(.top, 8)
            VStack(spacing: 0, content: content).modifier(SettingsCard())
        }
    }
    /// A full-width #1c1c23 hairline between rows.
    private var divider: some View { Rectangle().fill(Color(webHex: "#1c1c23")).frame(height: HomeStyle.hairline) }
    private var chevron: some View { Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#6a6a78")) }
    /// iOS Settings-style tiles: a white SF Symbol on a solid colour, fixed across themes.
    enum TileTint {
        case purple, indigo, blue, cyan, teal, mint, green, yellow, orange, red, pink, cloudflare
        var color: Color {
            switch self {
            case .purple: Color(webHex: "#8E5CF0")
            case .indigo: Color(webHex: "#5E5CE6")
            case .blue: Color(webHex: "#0A84FF")
            case .cyan: Color(webHex: "#32ADE6")
            case .teal: Color(webHex: "#30B0C7")
            case .mint: Color(webHex: "#00B8A3")
            case .green: Color(webHex: "#30B350")
            case .yellow: Color(webHex: "#F2B705")
            case .orange: Color(webHex: "#FF8A1F")
            case .red: Color(webHex: "#FF453A")
            case .pink: Color(webHex: "#FF375F")
            case .cloudflare: Color(webHex: "#F38020")
            }
        }
    }
    private func tile(_ symbol: String, _ tint: TileTint) -> some View {
        // Design: one style for every row, a #cdbbff icon on a 38 pt #2a2440 tile.
        Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(HomeStyle.chipText)
            .frame(width: 38, height: 38).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
    }
    private func settingsRow(_ icon: String, _ tint: TileTint, _ title: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = false, padded: Bool = true) -> some View {
        settingsRow(leading: tile(icon, tint), title, subtitle: subtitle, value: value, disclosure: disclosure, padded: padded)
    }
    private func settingsRow<Leading: View>(leading: Leading, _ title: String, subtitle: String?, value: String?, disclosure: Bool, padded: Bool) -> some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true) }
            }.layoutPriority(1)
            Spacer(minLength: 4)
            // The value gives way (one line, …) before the title wraps.
            if let value { Text(value).font(.system(size: 13, weight: title == "Connections" ? .semibold : .regular)).foregroundStyle(title == "Connections" ? HomeStyle.chipText : HomeStyle.secondary).lineLimit(1).truncationMode(.tail) }
            if disclosure { chevron }
        }.padding(.horizontal, padded ? 15 : 0).frame(minHeight: padded ? 64 : 40).contentShape(Rectangle())
    }
    private func exportDiary() {
        // Pretty, key-sorted JSON of the whole diary is encoded off the main actor.
        let snapshot = store.workspace
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try DiaryExport(workspace: snapshot).encoded() }.value
                exportDocument = DiaryJSONDocument(data: data); showExport = true
            } catch { store.error = error.localizedDescription }
        }
    }
}

/// Settings' card: #0e0e12, radius 22, a #23232b hairline (design).
struct SettingsCard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(HomeStyle.card, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HomeStyle.cardBorder, lineWidth: HomeStyle.hairline))
    }
}

struct DiaryJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct TMDBConnectionView: View {
    @Environment(DiaryStore.self) private var store
    @State private var checking = false
    @State private var verified = false
    @State private var error: String?
    @State private var editingApi = false
    @State private var tokenInput = ""
    @State private var savedMessage: String?

    var body: some View {
        EdgeToEdgeScroll {
            // Design (board 9): the service card with its two buttons, then one note.
            VStack(alignment: .leading, spacing: 14) {
                let custom = store.providerSettings.customTmdbToken != nil
                SettingsServiceHeader(logo: .tmdb, title: "TMDB", subtitle: "Posters, details and episodes",
                                      badge: verified ? ("Connected", .good) : checking ? ("Checking…", .plain) : ("Not connected", .missing)) {
                    HStack(spacing: 10) {
                        Button(checking ? "Checking…" : "Check connection") { Task { await check() } }
                            .buttonStyle(SettingsWideButtonStyle()).disabled(checking)
                        Button(editingApi ? "Hide" : "Change API key") {
                            tokenInput = store.providerSettings.customTmdbToken ?? ""
                            withAnimation(Motion.smooth) { editingApi.toggle() }
                            savedMessage = nil
                        }.buttonStyle(SettingsWideButtonStyle(outlined: true)).accessibilityIdentifier("tmdb-api-toggle")
                    }
                    if let error { Text(error).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let savedMessage { Text(savedMessage).font(.system(size: 13)).foregroundStyle(Color(webHex: "#7fe0b5")).accessibilityIdentifier("tmdb-api-saved") }
                }
                SettingsFootnote(text: custom
                    ? "Your own Read Access Token is stored encrypted on this iPhone and used first; your server’s key is the backup."
                    : "TMDB is read straight from this iPhone with your server’s key. You can also set your own TMDB Read Access Token here.")
                if editingApi {
                    SettingsGroup(label: "Your own token") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Paste a TMDB Read Access Token (without the word Bearer). It replaces the server’s key on this iPhone.")
                                .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                            SecureField("TMDB Read Access Token", text: $tokenInput).settingsField(monospaced: true)
                                .accessibilityIdentifier("tmdb-api-token-field")
                            HStack(spacing: 10) {
                                Button("Save") {
                                    guard store.updateCustomTmdbToken(tokenInput) else { savedMessage = store.error; return }
                                    savedMessage = "Your TMDB token is saved."
                                    verified = true
                                    editingApi = false
                                }.buttonStyle(SettingsWideButtonStyle())
                                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .accessibilityIdentifier("tmdb-api-save")
                                if custom {
                                    Button("Use server key") {
                                        tokenInput = ""
                                        guard store.updateCustomTmdbToken(nil) else { savedMessage = store.error; return }
                                        savedMessage = "Back to your server’s TMDB key."
                                        editingApi = false
                                    }.buttonStyle(SettingsWideButtonStyle(outlined: true)).accessibilityIdentifier("tmdb-api-reset")
                                }
                            }
                        }.padding(15)
                    }.accessibilityIdentifier("tmdb-api-panel")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }
        .diaryScreenBackground()
        .navigationTitle("TMDB")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await check() }
    }

    private func check() async {
        checking = true; error = nil
        defer { checking = false }
        if let custom = store.providerSettings.customTmdbToken, !custom.isEmpty {
            verified = true
            return
        }
        do {
            if store.isPreview {
            } else if store.phoneOnly {
                // No server: the key built into the app is checked with TMDB itself.
                guard let token = TMDBDirect.builtIn else { throw APIError.message("Add your own TMDB key below.") }
                _ = try await TMDBDirect.object("configuration", query: [:], token: token)
            } else {
                let _: EmptyResponse = try await store.read("/api/metadata/status")
            }
            verified = true
        } catch {
            verified = false
            self.error = error.localizedDescription
        }
    }
}

struct ExternalProviderConnectionView: View {
    let provider: SyncProviderKind
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var enabled = false
    @State private var loggingMethod: WatchLoggingMethod = .serverAndDirectAPI
    @State private var clientId = ""
    @State private var apiKey = ""
    @State private var accessToken = ""
    @State private var username = ""
    @State private var testing = false
    @State private var syncing = false
    @State private var deviceSession: DeviceCodeAuthSession?
    @State private var pollingPin = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    /// TwilDiary's own app client IDs from the server (Settings → APIs), for "Sign in with …".
    @State private var apps: ProviderApps?
    @State private var signingIn = false
    @State private var confirmTraktSignOut = false
    /// MDBList's code to approve on mdblist.com, while waiting for approval.
    @State private var approval: ProviderDeviceSignIn.Authorization?
    @Environment(\.openURL) private var openURL
    /// An app ID pasted on this page, for web sign-in before the server has one.
    @State private var signInAppID = ""
    @State private var signInTask: Task<Void, Never>?
    @State private var showOwnKey = false
    @FocusState private var appIDFocused: Bool
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    struct ProviderApps: Decodable { let trakt: String?; let mdblist: String? }

    private var brand: BrandLogo.Service {
        switch provider {
        case .mdblist: .mdblist
        case .wetrakr: .wetrakr
        case .trakt: .trakt
        case .cloudflare: .cloudflare
        }
    }

    private var displayName: String {
        switch provider {
        case .mdblist: "MDBList"
        case .wetrakr: "WeTrakr"
        case .trakt: "Trakt"
        case .cloudflare: "TwilDiary"
        }
    }

    private var subtitleText: String {
        switch provider {
        case .mdblist: "Public ratings, watch history and watchlist."
        case .wetrakr: "Watch history with rewatches, ratings and lists."
        case .trakt: "Watch history, ratings and watchlist."
        case .cloudflare: "Hosted diary sync."
        }
    }

    private var includedDomainsText: String {
        switch provider {
        case .mdblist: "Watch history · Ratings · Watchlist · Dropped shows"
        case .wetrakr: "Watch history · Ratings · Watchlist · Favourites · Dropped"
        case .trakt, .cloudflare: "Watch history · Ratings · Watchlist"
        }
    }

    private var currentConfig: ExternalProviderConfig {
        store.providerSettings.config(for: provider)
    }

    private var pendingOutboxCount: Int {
        store.outbox.pending(for: provider).count
    }

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                connectCard
                if currentConfig.isAuthenticated || pendingOutboxCount > 0 { sendEditsCard }
                if currentConfig.isAuthenticated, let tracker { TrackerPreviewPanel(tracker: tracker) }
                ownKeySection
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }
        .diaryScreenBackground()
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { loadFromStore() }
        .task { await loadApps() }
        .onDisappear { signInTask?.cancel(); signInTask = nil }
        .alert("Sign out of Trakt on this iPhone? Edits still waiting for Trakt stay queued until you sign in again.", isPresented: $confirmTraktSignOut) {
            Button("Sign out", role: .destructive) { Task { await store.signOutTraktOnPhone(); loadFromStore(); statusMessage = "Signed out of Trakt." } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var tracker: MainTracker? {
        switch provider { case .trakt: .trakt; case .mdblist: .mdblist; case .wetrakr: .wetrakr; case .cloudflare: nil }
    }

    /// One switch: whether your edits go to this service, and what's still on its way.
    private var sendEditsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send my edits to \(displayName)").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    Text("Sent as you make them.").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(SettingsToggleStyle()).padding(.horizontal, 15).frame(minHeight: 64)
                .onChange(of: enabled) { _, on in if on { loggingMethod = .serverAndDirectAPI }; persistDraft() }
                .accessibilityIdentifier("\(provider.rawValue)-enable-toggle")
            if pendingOutboxCount > 0 {
                SettingsDivider()
                HStack {
                    Text("\(pendingOutboxCount) waiting to send").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                        .accessibilityIdentifier("\(provider.rawValue)-outbox-count")
                    Spacer()
                    Button(syncing ? "Sending…" : "Send now") {
                        Task {
                            syncing = true; defer { syncing = false }
                            errorMessage = nil; statusMessage = nil
                            await store.flushDirectProviders()
                            let pending = store.outbox.pending(for: provider)
                            if pending.isEmpty { statusMessage = "Everything reached \(displayName)." }
                            else { errorMessage = "\(pending.count) still waiting. " + (pending.first?.lastError ?? "") }
                        }
                    }.buttonStyle(SettingsPillButtonStyle()).disabled(syncing || !currentConfig.isAuthenticated).accessibilityIdentifier("\(provider.rawValue)-sync-now")
                }.padding(.horizontal, 15).padding(.vertical, 10)
            }
        }.modifier(SettingsCard())
    }

    /// Your own key or token, folded away: signing in is the simple way.
    private var ownKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(Motion.smooth) { showOwnKey.toggle() } } label: {
                HStack {
                    Text(provider == .mdblist ? "Use an API key instead" : "Use your own key or token instead")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(webHex: "#6a6a78"))
                        .rotationEffect(.degrees(showOwnKey ? 180 : 0))
                }.padding(.horizontal, 15).frame(minHeight: 56).contentShape(Rectangle()).modifier(SettingsCard())
            }.buttonStyle(.plain).accessibilityIdentifier("\(provider.rawValue)-own-key")
            if showOwnKey { apiSettingsCard }
        }
    }

    /// Two ways in: sign in to the service, or (below) your own API key or token.
    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabel(text: "Connect") { EmptyView() }
            VStack(alignment: .leading, spacing: 12) {
                switch provider {
                case .trakt:
                    // Signed in on this iPhone: Trakt's own page, PKCE, tokens in the Keychain; the
                    // server isn't involved. A sign-in made earlier through the server still works.
                    let onPhone = store.traktSignedInOnPhone
                    let appId = appClientId ?? ProfileText.line(signInAppID)
                    Text(onPhone ? "Signed in on this iPhone\(currentConfig.username.map { " as @" + $0 } ?? "")."
                         : store.traktController.status?.connected == true ? "Signed in through your server. Sign in here to keep Trakt on this iPhone only."
                         : "Sign in on Trakt and come straight back.")
                        .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trakt-sign-in-state")
                    Button {
                        if let appId { startSignIn(appId) } else {
                            errorMessage = "First, paste your Trakt app’s client ID below (one-time setup)."
                            appIDFocused = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if signingIn { ProgressView().controlSize(.small) } else { Image(systemName: "person.crop.circle.badge.checkmark") }
                            Text(signingIn ? "Signing in…" : onPhone ? "Sign in again" : "Sign in with Trakt").lineLimit(1)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(signingIn).accessibilityIdentifier("trakt-sign-in")
                    if onPhone {
                        Button(role: .destructive) { confirmTraktSignOut = true } label: {
                            Text("Sign out of Trakt").frame(maxWidth: .infinity)
                        }.buttonStyle(SettingsDestructiveButtonStyle()).accessibilityIdentifier("trakt-sign-out")
                    }
                    NavigationLink(value: AppDestination.trakt) { SettingsLinkLabel(text: "Open the Trakt page") }
                        .accessibilityIdentifier("trakt-open-page")
                    SettingsDivider().padding(.horizontal, -15).padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("One-time setup").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Spacer(minLength: 8)
                            SettingsInfoButton(text: "On trakt.tv/oauth/applications, open your app and add \(ProviderWebSignIn.redirect(for: .trakt)) as a redirect URI (one per line, next to any you have).")
                        }
                        Text("Your Trakt app needs the redirect \(ProviderWebSignIn.redirect(for: .trakt)).")
                            .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        if appClientId == nil {
                            TextField("Trakt app client ID", text: $signInAppID).settingsField(monospaced: true)
                                .focused($appIDFocused)
                                .submitLabel(.go).onSubmit { if let id = ProfileText.line(signInAppID) { startSignIn(id) } }
                                .accessibilityIdentifier("trakt-sign-in-app-id")
                        }
                        Link(destination: URL(string: "https://trakt.tv/oauth/applications")!) { SettingsLinkLabel(text: "Open Trakt’s app settings") }
                    }
                case .mdblist, .wetrakr:
                    // Web sign-in is always offered: with TwilDiary's app ID from your server, or one
                    // you paste here once (a free \(displayName) app with redirect twildiary://auth/…).
                    let appId = appClientId ?? ProfileText.line(signInAppID)
                    Text("Sign in on \(displayName) and come straight back.")
                        .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let appId { startSignIn(appId) } else {
                            errorMessage = "First, paste your \(displayName) app ID below (one-time setup)."
                            appIDFocused = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if signingIn { ProgressView().controlSize(.small) } else { Image(systemName: "globe") }
                            Text(signingIn ? "Signing in…" : currentConfig.connection == .signIn && currentConfig.isAuthenticated ? "Sign in again" : "Sign in with \(displayName)")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(SettingsPrimaryButtonStyle()).disabled(signingIn).accessibilityIdentifier("\(provider.rawValue)-sign-in")
                    if let approval {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Approve TwilDiary on \(displayName) with this code:").font(.caption).foregroundStyle(.secondary)
                            Text(approval.userCode).font(.system(size: 26, weight: .bold, design: .monospaced)).textSelection(.enabled)
                                .accessibilityIdentifier("\(provider.rawValue)-user-code")
                            HStack(spacing: 10) {
                                Button("Open \(displayName)") { openURL(approval.verificationURLComplete ?? approval.verificationURL) }
                                    .buttonStyle(.diarySecondary)
                                Button("Cancel", role: .cancel) { signInTask?.cancel(); self.approval = nil; signingIn = false }
                                    .buttonStyle(.diarySecondary)
                            }.font(.subheadline)
                            Text("Waiting for approval… come back here afterwards; it finishes on its own.").font(.caption).foregroundStyle(.secondary)
                        }.padding(12).background(HomeStyle.round, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if appClientId == nil {
                        SettingsDivider().padding(.horizontal, -15).padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("One-time setup").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                Spacer(minLength: 8)
                                SettingsInfoButton(text: provider == .mdblist
                                    ? "Create a free “Device Code” app on MDBList’s developer page (no redirect needed), then paste its client ID here or under Connections → All keys."
                                    : provider == .wetrakr
                                    ? "In WeTrakr, open Settings → API, create an app with the redirect \(ProviderWebSignIn.redirect(for: provider)), then paste its client ID (the app key) here."
                                    : "Create a free V2 mobile app on \(displayName) with the redirect \(ProviderWebSignIn.redirect(for: provider)), then paste its client ID here or under Connections → All keys.")
                            }
                            Text(apps == nil ? "Checking for TwilDiary’s \(displayName) app…" : "Paste your \(displayName) client ID.")
                                .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("\(provider.rawValue)-sign-in-unavailable")
                            TextField("\(displayName) app client ID", text: $signInAppID).settingsField(monospaced: true)
                                .focused($appIDFocused)
                                .submitLabel(.go).onSubmit { if let id = ProfileText.line(signInAppID) { startSignIn(id) } }
                                .accessibilityIdentifier("\(provider.rawValue)-sign-in-app-id")
                            Link(destination: URL(string: provider == .wetrakr ? "https://api.wetrakr.com/" : "https://mdblist.com/developer/")!) {
                                SettingsLinkLabel(text: "Open \(displayName)’s developer page")
                            }
                        }
                    }
                case .cloudflare:
                    EmptyView()
                }
                messages
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
        }
    }
    private var appClientId: String? {
        let listed: String? = switch provider {
        case .mdblist: apps?.mdblist
        case .trakt: apps?.trakt
        case .wetrakr: nil
        case .cloudflare: nil
        }
        return listed.flatMap { $0.isEmpty ? nil : $0 } ?? ProviderAppIDs.id(for: provider)
    }
    private func loadApps() async {
        #if DEBUG
        if store.isPreview { apps = ProviderApps(trakt: "preview", mdblist: nil); return }
        #endif
        let loaded: ProviderApps? = try? await store.read("/api/providers/apps")
        if let loaded { ProviderAppIDs.remember([.trakt: loaded.trakt, .mdblist: loaded.mdblist]) }
        apps = loaded ?? ProviderApps(trakt: nil, mdblist: nil)
    }
    private func startSignIn(_ appId: String) {
        signInTask?.cancel()
        signInTask = Task { await runSignIn(appId) }
    }
    /// Opens the service's sign-in page in Apple's sign-in sheet; when it comes back approved, trades
    /// the code for tokens, saves them and turns sync on.
    private func runSignIn(_ appId: String) async {
        errorMessage = nil; statusMessage = nil
        // MDBList: its sign-in page (a Public PKCE app); an older "Device Code" app falls back to the code.
        if provider == .mdblist, ProviderAppIDs.id(for: .mdblist) == nil, appClientId == nil { await runDeviceSignIn(appId); return }
        guard let request = ProviderWebSignIn.start(provider: provider, clientId: appId) else {
            errorMessage = "TwilDiary can’t sign in to \(displayName) yet."; return
        }
        signingIn = true
        defer { signingIn = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(using: request.url, callbackURLScheme: ProviderWebSignIn.callbackScheme)
            let code = try ProviderWebSignIn.code(from: callback, for: request)
            let tokens = try await store.directClient.finishWebSignIn(request, code: code)
            if provider == .trakt {
                try await store.finishTraktPhoneSignIn(clientId: appId, tokens: tokens)
                loadFromStore()
                statusMessage = "Signed in to Trakt on this iPhone."
                return
            }
            var signedIn = currentConfig
            signedIn.clientId = appId; signedIn.accessToken = tokens.accessToken
            signedIn.refreshToken = tokens.refreshToken; signedIn.tokenExpiresAt = tokens.expiresAt
            signedIn.connection = .signIn; signedIn.enabled = true; signedIn.loggingMethod = .serverAndDirectAPI
            if provider == .mdblist { signedIn.apiKey = nil }
            guard store.updateProviderConfig(signedIn) else { throw APIError.message(store.error ?? "The sign-in couldn’t be saved.") }
            loadFromStore()
            statusMessage = "Signed in to \(displayName). Sync is on."
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closing the sheet is not an error.
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
    /// MDBList: its sign-in only redirects to web addresses, so it uses the device code instead.
    /// Shows the code, opens mdblist.com with it filled in, and asks every few seconds until approved.
    private func runDeviceSignIn(_ appId: String) async {
        signingIn = true
        defer { signingIn = false; approval = nil }
        do {
            let auth = try await store.directClient.startDeviceSignIn(provider: provider, clientId: appId)
            approval = auth
            openURL(auth.verificationURLComplete ?? auth.verificationURL)
            var interval = auth.interval
            let deadline = Date.now.addingTimeInterval(TimeInterval(auth.expiresIn))
            while Date.now < deadline {
                try await Task.sleep(for: .seconds(interval))
                switch try await store.directClient.pollDeviceSignIn(provider: provider, clientId: appId, deviceCode: auth.deviceCode) {
                case .pending: continue
                case .slowDown: interval += 5
                case .authorized(let tokens):
                    var signedIn = currentConfig
                    signedIn.clientId = appId; signedIn.accessToken = tokens.accessToken
                    signedIn.refreshToken = tokens.refreshToken; signedIn.tokenExpiresAt = tokens.expiresAt
                    signedIn.connection = .signIn; signedIn.enabled = true; signedIn.loggingMethod = .serverAndDirectAPI
                    signedIn.apiKey = nil
                    guard store.updateProviderConfig(signedIn) else { throw APIError.message(store.error ?? "The sign-in couldn’t be saved.") }
                    loadFromStore()
                    statusMessage = "Signed in to \(displayName). Sync is on."
                    return
                case .denied: throw APIError.message("The sign-in was declined.")
                case .expired: throw APIError.message("The code expired. Sign in again.")
                case .failed(let message): throw APIError.message(message)
                }
            }
            throw APIError.message("The code expired. Sign in again.")
        } catch {
            if !Task.isCancelled && !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder private var messages: some View {
        if let statusMessage {
            Text(statusMessage).font(.caption).foregroundStyle(.mint).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(provider.rawValue)-status-message")
        }
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(provider.rawValue)-error-message")
        }
    }

    private var headerCard: some View {
        let badge = currentConfig.statusBadge
        let tone: SettingsTone = badge == "Connected" ? .good : badge == "Configured" ? .configured : .plain
        return SettingsServiceHeader(logo: brand, title: displayName, subtitle: currentConfig.username.map { "@" + $0 } ?? subtitleText,
                                     badge: (badge, tone)) {
            SettingsKeeps(items: includedDomainsText.components(separatedBy: " · "))
            if let lastSync = currentConfig.lastSyncedAt, let date = DiaryDate.parse(lastSync) {
                Text("Last sent \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
            }
        }.accessibilityIdentifier("\(provider.rawValue)-status-badge")
    }

    private var apiSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                if provider == .mdblist {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MDBList API Key (apikey)").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        SecureField("Paste your MDBList API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .settingsField(monospaced: true)
                            .accessibilityIdentifier("\(provider.rawValue)-api-key-field")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Client ID (\(provider.rawValue)-api-key)")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        TextField("Your \(displayName) Client ID", text: $clientId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .settingsField(monospaced: true)
                            .accessibilityIdentifier("\(provider.rawValue)-client-id-field")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OAuth Access Token (Bearer)")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                        SecureField("Paste your access token", text: $accessToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .settingsField(monospaced: true)
                            .accessibilityIdentifier("\(provider.rawValue)-access-token-field")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account username (optional)").font(.system(size: 12, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .settingsField(monospaced: true)
                        .accessibilityIdentifier("\(provider.rawValue)-username-field")
                }

                InlineFlowLayout(spacing: 8, rowSpacing: 8) {
                    Button("Save") {
                        errorMessage = nil
                        if !enabled && draftConfig().hasCredentials { enabled = true }
                        var saved = draftConfig()
                        // New pasted credentials replace a sign-in: its refresh token belongs to the old token.
                        if saved.accessToken != currentConfig.accessToken || saved.apiKey != currentConfig.apiKey || saved.clientId != currentConfig.clientId {
                            saved.connection = .apiKey; saved.refreshToken = nil; saved.tokenExpiresAt = nil
                        }
                        if !store.updateProviderConfig(saved) { errorMessage = store.error; return }
                        statusMessage = "\(displayName) API settings saved."
                    }
                    .buttonStyle(SettingsPillButtonStyle())
                    .accessibilityIdentifier("\(provider.rawValue)-save-button")

                    Button(testing ? "Testing…" : "Test") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(SettingsPillButtonStyle(outlined: true))
                    .disabled(testing || !draftConfig().hasCredentials)
                    .accessibilityIdentifier("\(provider.rawValue)-test-button")

                    if currentConfig.hasCredentials {
                        Button("Disconnect", role: .destructive) {
                            enabled = false; clientId = ""; apiKey = ""; accessToken = ""; username = ""
                            deviceSession = nil; statusMessage = nil; errorMessage = nil
                            store.updateProviderConfig(ExternalProviderConfig(provider: provider))
                        }
                        .buttonStyle(SettingsPillButtonStyle(outlined: true))
                        .accessibilityIdentifier("\(provider.rawValue)-disconnect-button")
                    }

                    if provider == .trakt && !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Sign in with PIN") {
                            Task { await beginPinAuth() }
                        }
                        .buttonStyle(SettingsPillButtonStyle(outlined: true))
                        .disabled(testing || pollingPin)
                        .accessibilityIdentifier("\(provider.rawValue)-pin-auth-button")
                    }
                }

                if let auth = deviceSession {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Authorize \(displayName) with PIN code:")
                            .font(.caption.bold())
                        HStack {
                            Text(auth.userCode)
                                .font(.title3.monospaced().bold())
                                .foregroundStyle(theme.accent)
                            Spacer()
                            Link("Open \(auth.verificationURL.host ?? "activation page") ↗", destination: auth.verificationURL)
                                .font(.caption.weight(.semibold))
                        }
                        HStack(spacing: 10) {
                            Button(pollingPin ? "Checking…" : "I’ve authorized this PIN") {
                                Task { await checkPinAuthorization() }
                            }
                            .buttonStyle(SettingsPillButtonStyle())
                            .disabled(pollingPin)
                            Button("Cancel") { deviceSession = nil }
                                .buttonStyle(SettingsPillButtonStyle(outlined: true))
                        }
                    }
                    .padding(12)
                    .background(HomeStyle.round, in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
        }
    }

    private func loadFromStore() {
        let cfg = store.providerSettings.config(for: provider)
        enabled = cfg.enabled
        loggingMethod = cfg.loggingMethod
        clientId = cfg.clientId ?? ""
        apiKey = cfg.apiKey ?? ""
        accessToken = cfg.accessToken ?? ""
        username = cfg.username ?? ""
        if cfg.connection == .signIn, let id = cfg.clientId, !id.isEmpty { signInAppID = id }
    }

    private func draftConfig() -> ExternalProviderConfig {
        ExternalProviderConfig(
            provider: provider,
            enabled: enabled,
            loggingMethod: loggingMethod,
            clientId: clientId,
            apiKey: apiKey,
            accessToken: accessToken,
            username: username,
            lastSyncedAt: currentConfig.lastSyncedAt,
            // Toggles and the logging method keep how this was connected.
            refreshToken: currentConfig.refreshToken,
            tokenExpiresAt: currentConfig.tokenExpiresAt,
            connection: currentConfig.connection
        )
    }

    private func persistDraft() {
        if !store.updateProviderConfig(draftConfig()) { errorMessage = store.error }
    }

    private func testConnection() async {
        testing = true
        statusMessage = nil
        errorMessage = nil
        defer { testing = false }
        let cfg = draftConfig()
        do {
            try await store.testProviderConnection(cfg)
            var connectedCfg = cfg
            connectedCfg.enabled = true
            enabled = true
            guard store.updateProviderConfig(connectedCfg) else { errorMessage = store.error; return }
            statusMessage = "Connected to \(displayName) API."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginPinAuth() async {
        statusMessage = nil; errorMessage = nil
        do {
            deviceSession = try await store.directClient.requestDeviceCode(provider: provider, clientId: clientId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func checkPinAuthorization() async {
        guard let auth = deviceSession else { return }
        pollingPin = true; statusMessage = nil; errorMessage = nil
        defer { pollingPin = false }
        do {
            let result = try await store.directClient.pollDeviceToken(session: auth, clientId: clientId)
            switch result {
            case .authorized(let token):
                accessToken = token
                enabled = true
                deviceSession = nil
                var connectedCfg = draftConfig()
                connectedCfg.accessToken = token
                connectedCfg.enabled = true
                // Trakt's device codes issue no refresh token.
                connectedCfg.connection = .signIn; connectedCfg.refreshToken = nil; connectedCfg.tokenExpiresAt = nil
                guard store.updateProviderConfig(connectedCfg) else { errorMessage = store.error; return }
                statusMessage = "\(displayName) authorized and connected."
            case .expired:
                deviceSession = nil
                errorMessage = "PIN code expired. Request a new code to try again."
            case .pending:
                statusMessage = "Waiting for authorization at \(auth.verificationURL.absoluteString)…"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AboutView: View {
    var body: some View {
        EdgeToEdgeScroll { VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 12) { BrandMark().fill(.tint).frame(width: 54, height: 54); Text("TwilDiary").font(.title.bold()); Text("Your stories, at your pace.").foregroundStyle(.secondary); Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")").font(.caption) }.frame(maxWidth: .infinity).diaryPanel()
            VStack(alignment: .leading, spacing: 16) { Text("Attribution & licenses").font(.title2.bold()); Text("Movie & television data").font(.headline); Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.subheadline).foregroundStyle(.secondary); Link("The Movie Database ↗", destination: URL(string: "https://www.themoviedb.org")!); Text("Trakt").font(.headline); Text("Trakt connects your watch history, ratings and watchlist when you authorize it. Scanning prepares a review before changes are applied.").font(.subheadline).foregroundStyle(.secondary); Link("Trakt ↗", destination: URL(string: "https://trakt.tv")!); Text("Icons").font(.headline); Text("Lucide icons are provided under the ISC license.").font(.subheadline).foregroundStyle(.secondary) }.diaryPanel()
            if let url = Bundle.main.url(forResource: "Lucide-LICENSE", withExtension: "txt"), let license = try? String(contentsOf: url, encoding: .utf8) { DisclosureGroup("Lucide ISC license") { Text(license).font(.caption).textSelection(.enabled).padding(.top, 12) }.diaryPanel() }
        }.padding(16) }.diaryScreenBackground().navigationTitle("About").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
