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
    @AppStorage(MainTrackerView.key) private var mainTracker = MainTracker.trakt.rawValue
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
                VStack(alignment: .leading, spacing: 22) {
                    PageHeader(name: "Profile").padding(.horizontal, -14).padding(.bottom, -14)
                    NavigationLink(value: AppDestination.profile) {
                        HStack(spacing: 14) {
                            PersonalAvatar()
                            VStack(alignment: .leading, spacing: 3) { Text(PersonalProfile.shared.name).font(.title3.bold()); Text("Profile").font(.footnote).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-personal-profile")
                    NavigationLink(value: AppDestination.statistics) {
                        settingsRow("chart.bar.fill", .purple, "Statistics", subtitle: "Watch time and trends", disclosure: true)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-statistics")
                    diaryCard
                    if let warning = store.cacheWarning {
                        Text(warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4).accessibilityIdentifier("settings-cache-warning")
                    }
                    if let notice = store.providerVaultNotice {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Review provider settings sync") { reviewProviderConflict = true }.font(.subheadline)
                                .disabled(store.providerVaultBusy).accessibilityIdentifier("settings-review-vault")
                        }.padding(14).background(theme.field, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if store.pendingDiaryEdits > 0 {
                        settingsSection("Pending sync") {
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
                    settingsSection("Library") {
                        HStack(spacing: 12) {
                            tile("star.fill", .purple)
                            VStack(alignment: .leading, spacing: 2) { Text("Public ratings").font(.system(size: 15, weight: .semibold)); Text("Community scores, not your rating").font(.system(size: 12)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Menu { Picker("Library ratings", selection: $ratingSource) { ForEach(PublicRatingSource.allCases) { Text($0.label).tag($0) } } }
                                label: { FilterPill(label: ratingSource.label) }.fixedSize().accessibilityLabel("Library ratings").accessibilityValue(ratingSource.label).accessibilityIdentifier("settings-rating-source")
                        }.padding(.horizontal, 14).frame(minHeight: 60)
                        divider
                        NavigationLink(value: AppDestination.files) { settingsRow("externaldrive.fill", .green, "Files & drives", value: driveCount == 0 ? nil : String(driveCount), disclosure: true) }.accessibilityIdentifier("settings-files")
                        divider
                        NavigationLink(value: AppDestination.trash) { settingsRow("trash.fill", .red, "Trash", value: trashCount == 0 ? "Empty" : String(trashCount), disclosure: true) }
                    }
                    settingsSection("Tracking") {
                        HStack(spacing: 12) {
                            tile("eye.slash.fill", .indigo)
                            Toggle(isOn: $hideSpoilers) { VStack(alignment: .leading, spacing: 2) { Text("Hide spoilers").font(.system(size: 15, weight: .semibold)); Text("Names and stills until watched").font(.system(size: 12)).foregroundStyle(.secondary) } }.tint(theme.accent)
                        }.padding(.horizontal, 14).frame(minHeight: 60)
                        divider
                        NavigationLink(value: AppDestination.history) { settingsRow("clock.arrow.circlepath", .blue, "Watch history", subtitle: "Recently watched, dates and filters", disclosure: true) }.accessibilityIdentifier("settings-history")
                        divider
                        NavigationLink(value: AppDestination.calendar) { settingsRow("calendar", .indigo, "Airing calendar", subtitle: "Upcoming and catch-up episodes", disclosure: true) }.accessibilityIdentifier("settings-calendar")
                    }
                    Text("Weeks start on Monday. Ratings are whole numbers out of 10.").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.top, -14)
                    settingsSection("Appearance") {
                        NavigationLink(value: AppDestination.appearance) {
                            VStack(alignment: .leading, spacing: 8) {
                                settingsRow("paintpalette.fill", .pink, "Theme", value: theme.name, disclosure: true, padded: false)
                                // A glance at every theme; choosing one happens on the Theme page.
                                HStack(spacing: 8) {
                                    ForEach(DiaryTheme.allCases) { item in
                                        Circle().fill(item.accent).frame(width: 18, height: 18)
                                            .overlay { if item == theme { Circle().strokeBorder(.white, lineWidth: 2).padding(-4) } }
                                    }
                                }.padding(.leading, 46).padding(.bottom, 4).accessibilityHidden(true)
                            }.padding(.horizontal, 14).padding(.vertical, 10)
                        }.accessibilityIdentifier("settings-theme")
                        divider
                        HStack(spacing: 12) {
                            tile("rectangle.portrait.and.arrow.forward", .orange)
                            VStack(alignment: .leading, spacing: 2) { Text("Opens on").font(.system(size: 15, weight: .semibold)); Text("The screen TwilDiary starts on").font(.system(size: 12)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Menu { Picker("Opens on", selection: $launchTab) { ForEach(AppTab.allCases, id: \.self) { Text($0.label).tag($0) } } }
                                label: { FilterPill(label: launchTab.label) }.fixedSize().accessibilityLabel("Opens on").accessibilityValue(launchTab.label).accessibilityIdentifier("settings-launch-tab")
                        }.padding(.horizontal, 14).frame(minHeight: 60)
                        divider
                        settingsRow("circle.dotted.circle", .teal, "Reduce motion", value: reduceMotion ? "On · device" : "Follows device")
                        divider
                        settingsRow("globe.asia.australia.fill", .cyan, "Time zone", value: TimeZone.current.identifier.replacingOccurrences(of: "_", with: " "))
                    }
                    settingsSection("Connections and data") {
                        NavigationLink(value: AppDestination.connections) {
                            settingsRow(leading: BrandLogo(service: (MainTracker(rawValue: mainTracker) ?? .trakt).brand), "Connections",
                                        subtitle: "Trakt, Simkl, MDBList, TMDB, AniList and keys", value: connectionsSummary, disclosure: true, padded: true)
                        }.accessibilityIdentifier("settings-connections")
                        divider
                        Button { exportDiary() } label: { settingsRow("square.and.arrow.up.fill", .mint, "Export diary", subtitle: "Titles, progress, notes and file mappings", disclosure: true) }
                        divider
                        Button { showImport = true } label: { settingsRow("square.and.arrow.down.fill", .mint, "Import diary", subtitle: "TwilDiary JSON or Letterboxd, IMDb and MAL CSV", value: backupNotice, disclosure: true) }.accessibilityIdentifier("settings-import-diary")
                        divider
                        NavigationLink(value: AppDestination.backups) { settingsRow("externaldrive.badge.icloud", .teal, "Backups", subtitle: "Your whole diary and Trakt read, kept on your server", disclosure: true) }.accessibilityIdentifier("settings-backups")
                    }
                    VStack(spacing: 10) {
                        NavigationLink(value: AppDestination.about) {
                            Text("TwilDiary \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0") · About and licenses")
                                .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityIdentifier("settings-about")
                        Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Sign out", role: .destructive) { confirmSignOut = true }.font(.subheadline).frame(minHeight: 44).disabled(store.busy)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 24)
            }.refreshable { await store.refresh(); await summary?.refresh() }
        }
        .confirmationDialog(store.pendingDiaryEdits + TraktDirectStore.shared.pending.count > 0 ? "Sign out? Pending edits on this device, including any still waiting for Trakt, will be removed. Your hosted diary stays saved." : "Sign out on this device? Your hosted diary stays saved.", isPresented: $confirmSignOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { store.signOut() } }
        .confirmationDialog("Which provider settings should this device keep? Only your pending fields will change.", isPresented: $reviewProviderConflict, titleVisibility: .visible) {
            Button("Keep this device’s settings") { Task { await store.resolveProviderVaultConflict(keepDevice: true) } }
            Button("Use saved online settings") { Task { await store.resolveProviderVaultConflict(keepDevice: false) } }
        }
        .confirmationDialog("Discard all pending edits on this device? The latest hosted diary will be loaded first.", isPresented: $confirmDiscardPending, titleVisibility: .visible) {
            Button("Discard pending edits", role: .destructive) { Task { await store.discardPendingEdits() } }
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
    /// "Your diary": its state, what it holds, when it was last updated and what it's
    /// connected to. Tapping refreshes it from the server.
    private var diaryCard: some View {
        let titles = store.workspace.activeTitles.count, watches = store.workspace.activeEvents.count
        let state = store.loading ? "Refreshing…" : store.pendingDiaryEdits > 0 ? "Pending sync" : store.busy ? "Saving…" : store.quotaBlockedUntil != nil ? "Paused" : store.showingCachedSnapshot ? "Saved copy" : "Synced"
        let tint: Color = state == "Synced" ? .mint : state == "Paused" || state == "Saved copy" ? .orange : Color(webHex: "#c5c0cf")
        return Button { Task { await store.refresh() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Your diary").font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(state).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).padding(.horizontal, 10).frame(height: 24).background(tint.opacity(0.14), in: Capsule())
                }
                Text("\(titles.formatted()) \(titles == 1 ? "title" : "titles") · \(watches.formatted()) \(watches == 1 ? "watch" : "watches")" + (store.lastRefreshedAt.map { " · updated " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let reset = store.quotaBlockedUntil {
                    Text("Database allowance resumes " + reset.formatted(date: .abbreviated, time: .shortened) + ". Tap to check again.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    chip(BrandLogo(service: .trakt, size: 14), summary?.status?.connected == true ? "Trakt" : "Trakt off")
                    chip(BrandLogo(service: .tmdb, size: 16), "TMDB")
                    chip(DiaryIcon(name: "hard-drive", size: 13), driveCount == 1 ? "1 drive" : "\(driveCount) drives")
                }.padding(.top, 2)
            }.foregroundStyle(Color(webHex: "#f3f0f7")).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
                .contentShape(Rectangle())
        }.disabled(store.loading || store.busy).accessibilityIdentifier("settings-refresh-diary").accessibilityHint("Refresh your diary from the server")
    }
    private func chip(_ icon: some View, _ text: String) -> some View {
        HStack(spacing: 5) { icon; Text(text) }.font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(webHex: "#CECBF6")).padding(.horizontal, 9).frame(height: 26).background(.white.opacity(0.07), in: Capsule())
    }
    private var trashCount: Int { store.workspace.titles.reduce(0) { $0 + ($1.deletedAt == nil ? 0 : 1) } }
    private var driveCount: Int { DiskSummary.make(store.workspace.locations).count }
    /// Trakt's state in a word for its row; the full sync controls live on the Trakt page.
    /// "Trakt · 2 connected": the main tracker and how many services are signed in.
    private var connectionsSummary: String {
        let count = [store.traktController.status?.connected == true, store.providerSettings.simkl.isAuthenticated, store.providerSettings.mdblist.isAuthenticated].filter { $0 }.count
        return (MainTracker(rawValue: mainTracker) ?? .trakt).name + (count > 0 ? " · \(count) on" : "")
    }
    private func settingsSection<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0, content: content).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        }
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 60) }
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
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 34, height: 34).background(tint.color.gradient, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }
    private func settingsRow(_ icon: String, _ tint: TileTint, _ title: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = false, padded: Bool = true) -> some View {
        settingsRow(leading: tile(icon, tint), title, subtitle: subtitle, value: value, disclosure: disclosure, padded: padded)
    }
    private func settingsRow(_ brand: BrandLogo.Service, _ title: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = false) -> some View {
        settingsRow(leading: BrandLogo(service: brand), title, subtitle: subtitle, value: value, disclosure: disclosure, padded: true)
    }
    private func settingsRow<Leading: View>(leading: Leading, _ title: String, subtitle: String?, value: String?, disclosure: Bool, padded: Bool) -> some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(webHex: "#f3f0f7"))
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 4)
            if let value { Text(value).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            if disclosure { DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary) }
        }.padding(.horizontal, padded ? 14 : 0).frame(minHeight: padded ? 58 : 40).contentShape(Rectangle())
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

struct DiaryJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct TMDBConnectionView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var checking = false
    @State private var verified = false
    @State private var error: String?
    @State private var editingApi = false
    @State private var tokenInput = ""
    @State private var savedMessage: String?

    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        BrandLogo(service: .tmdb, size: 46)
                        Text("TMDB").font(.title2.bold())
                        Spacer()
                        Text(verified ? "Connected" : checking ? "Checking…" : store.providerSettings.customTmdbToken != nil ? "Custom API" : "Not connected")
                            .font(.caption.bold())
                            .foregroundStyle(verified || store.providerSettings.customTmdbToken != nil ? Color.mint : Color.secondary)
                    }
                    Text("Posters, title details, seasons and episodes.").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(checking ? "Checking…" : "Check connection") { Task { await check() } }
                            .buttonStyle(.glass).disabled(checking)
                        Button(editingApi ? "Hide API settings" : "Change API key") {
                            tokenInput = store.providerSettings.customTmdbToken ?? ""
                            editingApi.toggle()
                            savedMessage = nil
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("tmdb-api-toggle")
                    }
                    if let error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                    if let savedMessage { Text(savedMessage).font(.caption).foregroundStyle(.mint).accessibilityIdentifier("tmdb-api-saved") }
                    Text("API credentials stay on your server by default. You can also set or replace a custom TMDB Read Access Token here.")
                        .font(.caption).foregroundStyle(.secondary)
                }.diaryPanel()

                if editingApi {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            DiaryIcon(name: "key-round", size: 16).foregroundStyle(theme.accent)
                            Text("API settings").font(.headline)
                        }
                        Text("Enter a TMDB API Read Access Token (without the word Bearer) to override the default key.")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Paste your TMDB Read Access Token", text: $tokenInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                            .accessibilityIdentifier("tmdb-api-token-field")
                        HStack(spacing: 10) {
                            Button("Save API key") {
                                guard store.updateCustomTmdbToken(tokenInput) else { savedMessage = store.error; return }
                                savedMessage = "Custom TMDB API key saved."
                                verified = true
                                editingApi = false
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("tmdb-api-save")
                            if store.providerSettings.customTmdbToken != nil {
                                Button("Use server default", role: .destructive) {
                                    tokenInput = ""
                                    guard store.updateCustomTmdbToken(nil) else { savedMessage = store.error; return }
                                    savedMessage = "Reverted to server TMDB token."
                                    editingApi = false
                                }
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("tmdb-api-reset")
                            }
                        }
                    }.diaryPanel().accessibilityIdentifier("tmdb-api-panel")
                }
            }.padding(16)
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
            if !store.isPreview { let _: EmptyResponse = try await store.read("/api/metadata/status") }
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
    /// MDBList's code to approve on mdblist.com, while waiting for approval.
    @State private var approval: ProviderDeviceSignIn.Authorization?
    @Environment(\.openURL) private var openURL
    /// An app ID pasted on this page, for web sign-in before the server has one.
    @State private var signInAppID = ""
    @State private var signInTask: Task<Void, Never>?
    @State private var showOwnKey = false
    @FocusState private var appIDFocused: Bool
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    struct ProviderApps: Decodable { let trakt: String?; let simkl: String?; let mdblist: String? }

    private var brand: BrandLogo.Service {
        switch provider {
        case .simkl: .simkl
        case .mdblist: .mdblist
        case .trakt: .trakt
        case .cloudflare: .cloudflare
        }
    }

    private var displayName: String {
        switch provider {
        case .simkl: "Simkl"
        case .mdblist: "MDBList"
        case .trakt: "Trakt"
        case .cloudflare: "TwilDiary"
        }
    }

    private var subtitleText: String {
        switch provider {
        case .simkl: "Anime, TV and movie watch history, ratings and lists."
        case .mdblist: "Multi-source public ratings and watchlist sync."
        case .trakt: "Watch history, ratings and watchlist."
        case .cloudflare: "Hosted diary sync."
        }
    }

    private var includedDomainsText: String {
        switch provider {
        case .simkl: "Watch history · Ratings · Plan to watch · Dropped"
        case .mdblist: "Watch history · Ratings · Watchlist · Dropped shows"
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
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                connectCard
                if currentConfig.isAuthenticated || pendingOutboxCount > 0 { sendEditsCard }
                if currentConfig.isAuthenticated, let tracker { TrackerPreviewPanel(tracker: tracker) }
                ownKeySection
            }.padding(16).padding(.bottom, 60)
        }
        .diaryScreenBackground()
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { loadFromStore() }
        .task { await loadApps() }
        .onDisappear { signInTask?.cancel(); signInTask = nil }
    }

    private var tracker: MainTracker? {
        switch provider { case .trakt: .trakt; case .simkl: .simkl; case .mdblist: .mdblist; case .cloudflare: nil }
    }

    /// One switch: whether your edits go to this service, and what's still on its way.
    private var sendEditsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send my edits to \(displayName)").font(.subheadline.weight(.semibold))
                    Text("Watches, ratings, Planned and dropped, as you make them.").font(.caption).foregroundStyle(.secondary)
                }
            }.tint(theme.accent)
                .onChange(of: enabled) { _, on in if on { loggingMethod = .serverAndDirectAPI }; persistDraft() }
                .accessibilityIdentifier("\(provider.rawValue)-enable-toggle")
            if pendingOutboxCount > 0 {
                HStack {
                    Text("\(pendingOutboxCount) waiting to send").font(.caption).foregroundStyle(.secondary)
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
                    }.font(.caption.weight(.semibold)).disabled(syncing || !currentConfig.isAuthenticated).accessibilityIdentifier("\(provider.rawValue)-sync-now")
                }
            }
        }.diaryPanel()
    }

    /// Your own key or token, folded away: signing in is the simple way.
    private var ownKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(Motion.smooth) { showOwnKey.toggle() } } label: {
                HStack {
                    Text(provider == .mdblist ? "Use an API key instead" : "Use your own key or token instead").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showOwnKey ? 180 : 0)).font(.caption.weight(.bold))
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("\(provider.rawValue)-own-key")
            if showOwnKey { apiSettingsCard }
        }
    }

    /// Two ways in: sign in to the service, or (below) your own API key or token.
    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect").font(.subheadline.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                switch provider {
                case .trakt:
                    let connected = store.traktController.status?.connected == true
                    Text(connected ? "Signed in through TwilDiary." : "Sign in with your Trakt account on the Trakt page; TwilDiary keeps the connection.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    NavigationLink(value: AppDestination.trakt) {
                        Label(connected ? "Open Trakt" : "Sign in with Trakt", systemImage: "person.crop.circle.badge.checkmark").frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent).accessibilityIdentifier("trakt-sign-in")
                case .simkl, .mdblist:
                    // Web sign-in is always offered: with TwilDiary's app ID from your server, or one
                    // you paste here once (a free \(displayName) app with redirect twildiary://auth/…).
                    let appId = appClientId ?? ProfileText.line(signInAppID)
                    Text("Sign in on \(displayName)’s own page and come straight back. The sign-in renews itself.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    }.buttonStyle(.glassProminent).disabled(signingIn).accessibilityIdentifier("\(provider.rawValue)-sign-in")
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
                        }.padding(12).background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if appClientId == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(apps == nil ? "Checking for TwilDiary’s \(displayName) app…" : provider == .mdblist
                                 ? "One-time setup: create a free “Device Code” app on MDBList’s developer page (no redirect needed), then paste its client ID here (or under Connections → All keys)."
                                 : "One-time setup: create a free V2 mobile app on \(displayName) with the redirect \(ProviderWebSignIn.redirect(for: provider)), then paste its client ID here (or under Connections → All keys).")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("\(provider.rawValue)-sign-in-unavailable")
                            TextField("\(displayName) app client ID", text: $signInAppID)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().font(.subheadline).focused($appIDFocused)
                                .submitLabel(.go).onSubmit { if let id = ProfileText.line(signInAppID) { startSignIn(id) } }
                                .padding(10).background(theme.field, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("\(provider.rawValue)-sign-in-app-id")
                            Link(destination: URL(string: provider == .simkl ? "https://simkl.com/settings/developer/" : "https://mdblist.com/developer/")!) {
                                Label("Open \(displayName)’s developer page", systemImage: "arrow.up.right.square").font(.caption.weight(.semibold))
                            }
                        }
                    }
                case .cloudflare:
                    EmptyView()
                }
                messages
            }.diaryPanel()
        }
    }
    private var appClientId: String? {
        switch provider {
        case .simkl: apps?.simkl
        case .mdblist: apps?.mdblist
        case .trakt: apps?.trakt
        case .cloudflare: nil
        }
    }
    private func loadApps() async {
        #if DEBUG
        if store.isPreview { apps = ProviderApps(trakt: "preview", simkl: nil, mdblist: nil); return }
        #endif
        let loaded: ProviderApps? = try? await store.read("/api/providers/apps")
        apps = loaded ?? ProviderApps(trakt: nil, simkl: nil, mdblist: nil)
    }
    private func startSignIn(_ appId: String) {
        signInTask?.cancel()
        signInTask = Task { await runSignIn(appId) }
    }
    /// Opens the service's sign-in page in Apple's sign-in sheet; when it comes back approved, trades
    /// the code for tokens, saves them and turns sync on.
    private func runSignIn(_ appId: String) async {
        errorMessage = nil; statusMessage = nil
        if provider == .mdblist { await runDeviceSignIn(appId); return }
        guard let request = ProviderWebSignIn.start(provider: provider, clientId: appId) else {
            errorMessage = "TwilDiary can’t sign in to \(displayName) yet."; return
        }
        signingIn = true
        defer { signingIn = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(using: request.url, callbackURLScheme: ProviderWebSignIn.callbackScheme)
            let code = try ProviderWebSignIn.code(from: callback, for: request)
            let tokens = try await store.directClient.finishWebSignIn(request, code: code)
            guard ProviderDeviceSignIn.grantsWrite(tokens, provider: provider) else {
                throw APIError.message("\(displayName) gave read-only access. Sign in again and allow TwilDiary to make changes.")
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
        let color: Color = badge == "Connected" ? .mint : badge == "Configured" ? .yellow : .secondary
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandLogo(service: brand, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName).font(.title3.bold())
                    Text(currentConfig.username.map { "@" + $0 } ?? subtitleText)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(badge)
                    .font(.caption.bold())
                    .foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(color.opacity(0.12), in: Capsule())
                    .accessibilityIdentifier("\(provider.rawValue)-status-badge")
            }
            if let lastSync = currentConfig.lastSyncedAt, let date = DiaryDate.parse(lastSync) {
                Text("Last sent \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Keeps: \(includedDomainsText)")
                .font(.caption).foregroundStyle(.secondary)
        }.diaryPanel()
    }

    private var apiSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(provider == .trakt ? "Or use your own Trakt app" : "Or use your own API key or token").font(.subheadline.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                if provider == .mdblist {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MDBList API Key (apikey)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SecureField("Paste your MDBList API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                            .accessibilityIdentifier("\(provider.rawValue)-api-key-field")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Client ID (\(provider.rawValue)-api-key)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Your \(displayName) Client ID", text: $clientId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                            .accessibilityIdentifier("\(provider.rawValue)-client-id-field")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OAuth Access Token (Bearer)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SecureField("Paste your access token", text: $accessToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                            .accessibilityIdentifier("\(provider.rawValue)-access-token-field")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account username (optional)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                        .accessibilityIdentifier("\(provider.rawValue)-username-field")
                }

                HStack(spacing: 10) {
                    Button("Save API settings") {
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
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("\(provider.rawValue)-save-button")

                    Button(testing ? "Testing…" : "Test API") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(.glass)
                    .disabled(testing || !draftConfig().hasCredentials)
                    .accessibilityIdentifier("\(provider.rawValue)-test-button")

                    if currentConfig.hasCredentials {
                        Button("Disconnect", role: .destructive) {
                            enabled = false; clientId = ""; apiKey = ""; accessToken = ""; username = ""
                            deviceSession = nil; statusMessage = nil; errorMessage = nil
                            store.updateProviderConfig(ExternalProviderConfig(provider: provider))
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("\(provider.rawValue)-disconnect-button")
                    }

                    if (provider == .simkl || provider == .trakt) && !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Sign in with PIN") {
                            Task { await beginPinAuth() }
                        }
                        .buttonStyle(.glass)
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
                            .buttonStyle(.glassProminent)
                            .disabled(pollingPin)
                            Button("Cancel") { deviceSession = nil }
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(12)
                    .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                }
            }.diaryPanel()
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
                // Simkl's PIN and Trakt's device codes issue no refresh token.
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
