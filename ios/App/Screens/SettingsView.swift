import SwiftUI
import TwilDiaryCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("publicRatingSource") private var ratingSource = PublicRatingSource.tmdb
    @AppStorage("hideSpoilers") private var hideSpoilers = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSearch = false
    @State private var confirmSignOut = false
    @State private var summary: TraktController?
    @State private var showExport = false
    @State private var showImport = false
    @State private var showSignInMethods = false
    @State private var backupNotice: String?
    @State private var exportDocument = DiaryJSONDocument(data: Data())
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(name: "More", onSearch: { showSearch.toggle() })
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    traktSummary
                    settingsSection("Library") {
                        HStack(spacing: 8) { settingsIcon("star"); VStack(alignment: .leading, spacing: 3) { Text("Library ratings").font(.subheadline.weight(.semibold)); Text("Community scores, not your rating").font(.caption).foregroundStyle(.secondary) }; Spacer(minLength: 0); Picker("Library ratings", selection: $ratingSource) { ForEach(PublicRatingSource.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu).font(.caption).fixedSize().accessibilityIdentifier("settings-rating-source") }.padding(14)
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.files) { settingsRow("hard-drive", "Files & drives", subtitle: "Folders, seasons and local copies", disclosure: true) }.accessibilityIdentifier("settings-files")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.trash) { settingsRow("trash-2", "Trash", subtitle: trashSubtitle, disclosure: true) }
                    }
                    settingsSection("Tracking") {
                        HStack(spacing: 8) { settingsIcon("eye-off"); Toggle(isOn: $hideSpoilers) { VStack(alignment: .leading, spacing: 3) { Text("Hide episode spoilers").font(.subheadline.weight(.semibold)); Text("Hide unwatched titles, summaries and images").font(.caption).foregroundStyle(.secondary) } }.tint(theme.accent) }.padding(14)
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.history) { settingsRow("history", "Watch history", subtitle: "Recently watched, dates and filters", disclosure: true) }.accessibilityIdentifier("settings-history")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.calendar) { settingsRow("calendar-days", "Airing calendar", subtitle: "Upcoming episodes for anime and TV shows", disclosure: true) }.accessibilityIdentifier("settings-calendar")
                        Divider().padding(.leading, 58)
                        settingsRow("star", "Rating scale", value: "10 · decimals")
                    }
                    settingsSection("Appearance & region") {
                        NavigationLink(value: AppDestination.appearance) { settingsRow("palette", "Theme", value: theme.name, disclosure: true) }.accessibilityIdentifier("settings-theme")
                        Divider().padding(.leading, 58)
                        settingsRow("activity", "Reduce motion", value: reduceMotion ? "Reduced · device" : "Follow device")
                        Divider().padding(.leading, 58)
                        settingsRow("globe", "Time zone", subtitle: "Uses your device for dates and stats", value: TimeZone.current.identifier.replacingOccurrences(of: "_", with: " "))
                        Divider().padding(.leading, 58)
                        settingsRow("calendar-days", "Week starts on", value: "Monday")
                    }
                    settingsSection("Connections") {
                        NavigationLink(value: AppDestination.tmdb) {
                            providerSettingsRow(
                                .tmdb,
                                "TMDB",
                                subtitle: "Posters, details, seasons and episodes",
                                value: store.providerSettings.customTmdbToken != nil ? "Custom API" : nil,
                                disclosure: true
                            )
                        }.accessibilityIdentifier("settings-tmdb")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.trakt) {
                            providerSettingsRow(
                                .trakt,
                                "Trakt",
                                subtitle: "History, ratings and watchlist",
                                value: summary?.status?.needsReconnect == true ? "Reconnect" : (summary?.status?.connected == true || store.providerSettings.trakt.isAuthenticated) ? "Connected" : store.providerSettings.trakt.hasCredentials ? "Configured" : "Set up",
                                disclosure: true
                            )
                        }.accessibilityIdentifier("settings-trakt")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.wetrakr) {
                            providerSettingsRow(
                                .wetrakr,
                                "WeTrakr",
                                subtitle: "Compact sync, decimal ratings and favorites",
                                value: store.providerSettings.wetrakr.statusBadge,
                                disclosure: true
                            )
                        }.accessibilityIdentifier("settings-wetrakr")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.simkl) {
                            providerSettingsRow(
                                .simkl,
                                "Simkl",
                                subtitle: "Anime, TV and movie watch tracking",
                                value: store.providerSettings.simkl.statusBadge,
                                disclosure: true
                            )
                        }.accessibilityIdentifier("settings-simkl")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.mdblist) {
                            providerSettingsRow(
                                .mdblist,
                                "MDBList",
                                subtitle: "Multi-source ratings and watchlist sync",
                                value: store.providerSettings.mdblist.statusBadge,
                                disclosure: true
                            )
                        }.accessibilityIdentifier("settings-mdblist")
                    }
                    settingsSection("Data & backup") {
                        Button { exportDiary() } label: { settingsRow("download", "Export diary", subtitle: "Titles, progress, notes and file mappings", disclosure: true) }
                        Divider().padding(.leading, 58)
                        Button { showImport = true } label: { settingsRow("arrow-down-up", "Import diary", subtitle: "TwilDiary JSON backup or Letterboxd, IMDb & MAL CSV", value: backupNotice, disclosure: true) }
                            .accessibilityIdentifier("settings-import-diary")
                        Divider().padding(.leading, 58)
                        Button { showSignInMethods = true } label: {
                            settingsRow("key-round", "Sign-in methods", subtitle: "Access Token, Owner Passcode, Trakt OAuth or Cloudflare SSO", disclosure: true)
                        }.accessibilityIdentifier("settings-signin-methods")
                        Divider().padding(.leading, 58)
                        Button { Task { await store.refresh() } } label: {
                            settingsRow("shield-check", "Diary storage", subtitle: storageDetail, value: store.loading ? "Refreshing…" : store.busy ? "Saving…" : store.showingCachedSnapshot ? "Saved copy" : "Ready")
                        }.disabled(store.loading || store.busy).accessibilityIdentifier("settings-refresh-diary").accessibilityHint("Refresh your diary from the server")
                    }
                    if let warning = store.cacheWarning {
                        Text(warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4).accessibilityIdentifier("settings-cache-warning")
                    }
                    settingsSection("About") {
                        NavigationLink(value: AppDestination.about) { settingsRow("info", "About TwilDiary", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0", disclosure: true) }.accessibilityIdentifier("settings-about")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.about) { settingsRow("shield-check", "Attribution & licenses", disclosure: true) }
                    }
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    Button("Sign out", role: .destructive) { confirmSignOut = true }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44).disabled(store.busy)
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 24)
            }.refreshable { await store.refresh(); await summary?.refresh() }
        }.confirmationDialog("Sign out on this device? Your hosted diary stays saved.", isPresented: $confirmSignOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { store.signOut() } }
            .sheet(isPresented: $showSignInMethods) {
                NavigationStack {
                    AccessSignIn { credential in
                        showSignInMethods = false
                        Task { await store.connect(credential) }
                    }
                    .navigationTitle("Sign-in methods")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showSignInMethods = false }
                        }
                    }
                }
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
    /// One pass over the library instead of three per render.
    private var trashSubtitle: String {
        let removed = store.workspace.titles.reduce(0) { $0 + ($1.deletedAt == nil ? 0 : 1) }
        return removed == 0 ? "No removed titles" : "\(removed) removed \(removed == 1 ? "title" : "titles")"
    }
    private var storageDetail: String {
        if let reset = store.quotaBlockedUntil { return "Database allowance resumes " + reset.formatted(date: .abbreviated, time: .shortened) + ". Tap to check again." }
        let detail = store.showingCachedSnapshot ? "Using the saved copy on this device. Tap to refresh." : "Your diary is saved to your workspace. Tap to refresh."
        guard let date = store.lastRefreshedAt else { return detail }
        return detail + " Last updated " + date.formatted(date: .abbreviated, time: .shortened) + "."
    }
    private var traktSummary: some View {
        let value = TraktOverview(status: summary?.status, sync: summary?.sync, checked: summary?.status != nil || summary?.error != nil, unavailable: summary?.error != nil)
        let color: Color = value.attention ? .yellow : value.badge == "Connected" ? .mint : .secondary
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) { DiaryIcon(name: "link-2", size: 16); Text("Trakt sync").font(.caption.bold()) }
                Spacer(minLength: 0)
                Text(value.badge).font(.caption2.bold()).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.1), in: Capsule()).accessibilityIdentifier("settings-trakt-badge")
            }
            Text(value.title).font(.system(size: 20, weight: .semibold)).accessibilityIdentifier("settings-trakt-title")
            Text(value.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
            NavigationLink(value: AppDestination.trakt) { Text(value.action).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).frame(height: 42).foregroundStyle(theme.ink).background(theme.accent, in: RoundedRectangle(cornerRadius: 12)) }.accessibilityIdentifier("settings-trakt-summary")
        }.diaryPanel()
    }
    private func settingsSection<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4); VStack(spacing: 0, content: content).diarySectionBackground(radius: 16, stroke: .white.opacity(0.08)) }
    }
    private func settingsIcon(_ icon: String) -> some View { DiaryIcon(name: icon, size: 18).foregroundStyle(theme.accent).frame(width: 34, height: 34).background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
    private func providerSettingsIcon(_ provider: ConnectionProviderIconKind) -> some View {
        ProviderBrandIcon(provider: provider, size: 18).foregroundStyle(theme.accent).frame(width: 34, height: 34).background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
    private func settingsRow(_ icon: String, _ title: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = false) -> some View {
        HStack(spacing: 10) { settingsIcon(icon); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white); if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }; Spacer(minLength: 4); if let value { Text(value).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }; if disclosure { DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary) } }.padding(14).frame(minHeight: 58).contentShape(Rectangle())
    }
    private func providerSettingsRow(_ provider: ConnectionProviderIconKind, _ title: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = false) -> some View {
        HStack(spacing: 10) { providerSettingsIcon(provider); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white); if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }; Spacer(minLength: 4); if let value { Text(value).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }; if disclosure { DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary) } }.padding(14).frame(minHeight: 58).contentShape(Rectangle())
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        ProviderBrandIcon(provider: .tmdb, size: 22)
                            .foregroundStyle(theme.accent)
                            .padding(12)
                            .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
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
                                store.updateCustomTmdbToken(tokenInput)
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
                                    store.updateCustomTmdbToken(nil)
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

    private var iconKind: ConnectionProviderIconKind {
        switch provider {
        case .wetrakr: .wetrakr
        case .simkl: .simkl
        case .mdblist: .mdblist
        case .trakt: .trakt
        case .cloudflare: .tmdb
        }
    }

    private var displayName: String {
        switch provider {
        case .wetrakr: "WeTrakr"
        case .simkl: "Simkl"
        case .mdblist: "MDBList"
        case .trakt: "Trakt"
        case .cloudflare: "TwilDiary"
        }
    }

    private var subtitleText: String {
        switch provider {
        case .wetrakr: "Compact sync, decimal ratings, watchlist and favorites."
        case .simkl: "Anime, TV and movie watch history, ratings and lists."
        case .mdblist: "Multi-source public ratings and watchlist sync."
        case .trakt: "Watch history, ratings and watchlist."
        case .cloudflare: "Hosted diary sync."
        }
    }

    private var includedDomainsText: String {
        switch provider {
        case .wetrakr: "Watch history · Decimal ratings (0.5–10) · Watchlist · Favorites · Dropped"
        case .simkl: "Watch history · Ratings · Plan to watch · Dropped"
        case .mdblist: "IMDb / RT / Metacritic / Letterboxd ratings · Watchlist"
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                loggingCard
                apiSettingsCard
                if currentConfig.hasCredentials || pendingOutboxCount > 0 {
                    syncOutboxCard
                }
            }.padding(16).padding(.bottom, 60)
        }
        .diaryScreenBackground()
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { loadFromStore() }
    }

    private var headerCard: some View {
        let badge = currentConfig.statusBadge
        let color: Color = badge == "Connected" ? .mint : badge == "Configured" ? .yellow : .secondary
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProviderBrandIcon(provider: iconKind, size: 22)
                    .foregroundStyle(theme.accent)
                    .padding(12)
                    .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
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
                Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Included in sync: \(includedDomainsText)")
                .font(.caption).foregroundStyle(.secondary)
        }.diaryPanel()
    }

    private var loggingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch logging & sync").font(.subheadline.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable \(displayName) sync", isOn: $enabled)
                    .tint(theme.accent)
                    .onChange(of: enabled) { _, _ in persistDraft() }
                    .accessibilityIdentifier("\(provider.rawValue)-enable-toggle")
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Logging method").font(.subheadline.weight(.semibold))
                        Text("Keeps your diary watch logging and fans out to \(displayName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Picker("Logging method", selection: $loggingMethod) {
                        ForEach(WatchLoggingMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: loggingMethod) { _, _ in persistDraft() }
                    .accessibilityIdentifier("\(provider.rawValue)-logging-method")
                }
            }.diaryPanel()
        }
    }

    private var apiSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API settings").font(.subheadline.bold()).foregroundStyle(.secondary)
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
                        Text(provider == .wetrakr ? "WeTrakr App API Key (wetrakr-api-key)" : "Client ID (\(provider.rawValue)-api-key)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField(provider == .wetrakr ? "wtk_..." : "Your \(displayName) Client ID", text: $clientId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(theme.field, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                            .accessibilityIdentifier("\(provider.rawValue)-client-id-field")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(provider == .wetrakr ? "Access Token or PAT (Bearer)" : "OAuth Access Token (Bearer)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SecureField(provider == .wetrakr ? "wtk_pat_..." : "Paste your access token", text: $accessToken)
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

                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.mint)
                        .accessibilityIdentifier("\(provider.rawValue)-status-message")
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("\(provider.rawValue)-error-message")
                }

                HStack(spacing: 10) {
                    Button("Save API settings") {
                        errorMessage = nil
                        if !enabled && draftConfig().hasCredentials { enabled = true }
                        persistDraft()
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

    private var syncOutboxCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Outbox & direct sync").font(.headline)
                Spacer()
                Text("\(pendingOutboxCount) queued").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(provider.rawValue)-outbox-count")
            }
            Text("Logged watches, ratings and watchlist changes queue locally first and sync with \(displayName) in the background.")
                .font(.caption).foregroundStyle(.secondary)
            Button(syncing ? "Syncing…" : "Sync now", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                Task {
                    syncing = true
                    defer { syncing = false }
                    await store.flushDirectProviders()
                    if (provider == .wetrakr || provider == .simkl), !store.isPreview {
                        struct PullReceipt: Decodable { let importedPlays: Int; let updatedRatings: Int }
                        if let receipt: PullReceipt = try? await store.read(
                            "/api/providers/\(provider.rawValue)/sync",
                            method: "POST",
                            body: ["clientId": clientId, "accessToken": accessToken]
                        ) {
                            if receipt.importedPlays > 0 || receipt.updatedRatings > 0 {
                                await store.refresh()
                            }
                            statusMessage = "Synced with \(displayName) (\(receipt.importedPlays) plays, \(receipt.updatedRatings) ratings pulled)."
                            return
                        }
                    }
                    statusMessage = "Synced pending changes with \(displayName)."
                }
            }
            .buttonStyle(.glass)
            .disabled(syncing || !currentConfig.isAuthenticated)
            .accessibilityIdentifier("\(provider.rawValue)-sync-now")
        }.diaryPanel()
    }

    private func loadFromStore() {
        let cfg = store.providerSettings.config(for: provider)
        enabled = cfg.enabled
        loggingMethod = cfg.loggingMethod
        clientId = cfg.clientId ?? ""
        apiKey = cfg.apiKey ?? ""
        accessToken = cfg.accessToken ?? ""
        username = cfg.username ?? ""
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
            lastSyncedAt: currentConfig.lastSyncedAt
        )
    }

    private func persistDraft() {
        store.updateProviderConfig(draftConfig())
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
            store.updateProviderConfig(connectedCfg)
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
                connectedCfg.lastSyncedAt = store.now.ISO8601Format()
                store.updateProviderConfig(connectedCfg)
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
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 12) { BrandMark().fill(.tint).frame(width: 54, height: 54); Text("TwilDiary").font(.title.bold()); Text("Your stories, at your pace.").foregroundStyle(.secondary); Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")").font(.caption) }.frame(maxWidth: .infinity).diaryPanel()
            VStack(alignment: .leading, spacing: 16) { Text("Attribution & licenses").font(.title2.bold()); Text("Movie & television data").font(.headline); Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.subheadline).foregroundStyle(.secondary); Link("The Movie Database ↗", destination: URL(string: "https://www.themoviedb.org")!); Text("Trakt").font(.headline); Text("Trakt connects your watch history, ratings and watchlist when you authorize it. Scanning prepares a review before changes are applied.").font(.subheadline).foregroundStyle(.secondary); Link("Trakt ↗", destination: URL(string: "https://trakt.tv")!); Text("Icons").font(.headline); Text("Lucide icons are provided under the ISC license.").font(.subheadline).foregroundStyle(.secondary) }.diaryPanel()
            if let url = Bundle.main.url(forResource: "Lucide-LICENSE", withExtension: "txt"), let license = try? String(contentsOf: url, encoding: .utf8) { DisclosureGroup("Lucide ISC license") { Text(license).font(.caption).textSelection(.enabled).padding(.top, 12) }.diaryPanel() }
        }.padding(16) }.diaryScreenBackground().navigationTitle("About").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
