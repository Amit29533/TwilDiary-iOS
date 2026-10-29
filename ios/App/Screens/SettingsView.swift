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
    @State private var exportDocument = DiaryJSONDocument(data: Data())
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(name: "Settings", onSearch: { showSearch.toggle() })
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    diaryCard
                    if let warning = store.cacheWarning {
                        Text(warning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4).accessibilityIdentifier("settings-cache-warning")
                    }
                    traktSummary
                    settingsSection("Library") {
                        HStack(spacing: 12) {
                            tile("star", .purple)
                            VStack(alignment: .leading, spacing: 2) { Text("Public ratings").font(.system(size: 15, weight: .semibold)); Text("Community scores, not your rating").font(.system(size: 12)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Picker("Library ratings", selection: $ratingSource) { ForEach(PublicRatingSource.allCases) { Text($0.label).tag($0) } }
                                .pickerStyle(.menu).tint(theme.accent).fixedSize().accessibilityIdentifier("settings-rating-source")
                        }.padding(.horizontal, 14).frame(minHeight: 60)
                        divider
                        NavigationLink(value: AppDestination.files) { settingsRow("hard-drive", .green, "Files & drives", value: driveCount == 0 ? nil : String(driveCount), disclosure: true) }.accessibilityIdentifier("settings-files")
                        divider
                        NavigationLink(value: AppDestination.trash) { settingsRow("trash-2", .coral, "Trash", value: trashCount == 0 ? "Empty" : String(trashCount), disclosure: true) }
                    }
                    settingsSection("Tracking") {
                        HStack(spacing: 12) {
                            tile("eye-off", .purple)
                            Toggle(isOn: $hideSpoilers) { VStack(alignment: .leading, spacing: 2) { Text("Hide spoilers").font(.system(size: 15, weight: .semibold)); Text("Names and stills until watched").font(.system(size: 12)).foregroundStyle(.secondary) } }.tint(theme.accent)
                        }.padding(.horizontal, 14).frame(minHeight: 60)
                        divider
                        NavigationLink(value: AppDestination.history) { settingsRow("history", .blue, "Watch history", subtitle: "Recently watched, dates and filters", disclosure: true) }.accessibilityIdentifier("settings-history")
                        divider
                        settingsRow("calendar-days", .blue, "Week starts on", value: "Monday")
                        divider
                        settingsRow("star", .blue, "Rating scale", value: "10 · decimals")
                    }
                    settingsSection("Appearance") {
                        NavigationLink(value: AppDestination.appearance) {
                            VStack(alignment: .leading, spacing: 8) {
                                settingsRow("palette", .pink, "Theme", value: theme.name, disclosure: true, padded: false)
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
                        settingsRow("activity", .gray, "Reduce motion", value: reduceMotion ? "On · device" : "Follows device")
                        divider
                        settingsRow("globe", .gray, "Time zone", value: TimeZone.current.identifier.replacingOccurrences(of: "_", with: " "))
                    }
                    settingsSection("Connections and data") {
                        NavigationLink(value: AppDestination.trakt) { settingsRow("link-2", .purple, "Trakt", subtitle: "History, ratings and watchlist", value: summary?.status?.needsReconnect == true ? "Reconnect" : summary?.status?.connected == true ? "Connected" : "Set up", disclosure: true) }.accessibilityIdentifier("settings-trakt")
                        divider
                        NavigationLink(value: AppDestination.tmdb) { settingsRow("database", .blue, "TMDB", subtitle: "Posters, details, seasons and episodes", disclosure: true) }.accessibilityIdentifier("settings-tmdb")
                        divider
                        Button { exportDiary() } label: { settingsRow("download", .green, "Export diary", subtitle: "Titles, progress, notes and file mappings", disclosure: true) }
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
        }.confirmationDialog("Sign out on this device? Your hosted diary stays saved.", isPresented: $confirmSignOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { store.signOut() } }
            .task(id: store.sessionRevision) { summary = TraktController(service: makeTraktService(store: store)); await summary?.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await summary?.refresh() } } }
            .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json, defaultFilename: "TwilDiary-\(DiaryDate.day(store.now))") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
    }
    /// "Your diary": its state, what it holds, when it was last updated and what it's
    /// connected to. Tapping refreshes it from the server.
    private var diaryCard: some View {
        let titles = store.workspace.activeTitles.count, watches = store.workspace.activeEvents.count
        let state = store.loading ? "Refreshing…" : store.busy ? "Saving…" : store.quotaBlockedUntil != nil ? "Paused" : store.showingCachedSnapshot ? "Saved copy" : "Synced"
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
                    chip("link-2", summary?.status?.connected == true ? "Trakt" : "Trakt off")
                    chip("database", "TMDB")
                    chip("hard-drive", driveCount == 1 ? "1 drive" : "\(driveCount) drives")
                }.padding(.top, 2)
            }.foregroundStyle(Color(webHex: "#f3f0f7")).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.field, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
                .contentShape(Rectangle())
        }.disabled(store.loading || store.busy).accessibilityIdentifier("settings-refresh-diary").accessibilityHint("Refresh your diary from the server")
    }
    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) { DiaryIcon(name: icon, size: 13); Text(text) }.font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(webHex: "#CECBF6")).padding(.horizontal, 9).frame(height: 26).background(.white.opacity(0.07), in: Capsule())
    }
    private var trashCount: Int { store.workspace.titles.reduce(0) { $0 + ($1.deletedAt == nil ? 0 : 1) } }
    private var driveCount: Int { DiskSummary.make(store.workspace.locations).count }
    private var traktSummary: some View {
        let value = TraktOverview(status: summary?.status, sync: summary?.sync, checked: summary?.status != nil || summary?.error != nil, unavailable: summary?.error != nil)
        let color: Color = value.attention ? .orange : value.badge == "Connected" ? .mint : Color(webHex: "#c5c0cf")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                tile("link-2", .purple)
                Text("Trakt sync").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Text(value.badge).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).padding(.horizontal, 10).frame(height: 24).background(color.opacity(0.14), in: Capsule()).accessibilityIdentifier("settings-trakt-badge")
            }
            Text(value.title).font(.system(size: 18, weight: .semibold)).accessibilityIdentifier("settings-trakt-title")
            Text(value.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: AppDestination.trakt) {
                Text(value.action).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 46).foregroundStyle(theme.ink).background(theme.accent, in: Capsule())
            }.accessibilityIdentifier("settings-trakt-summary")
        }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
    }
    private func settingsSection<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0, content: content).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        }
    }
    private var divider: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 60) }
    /// Coloured icon tiles group the rows at a glance; colours are fixed across themes.
    enum TileTint {
        case purple, green, coral, blue, pink, gray
        var colors: (Color, Color) {
            switch self {
            case .purple: (Color(webHex: "#3C3489"), Color(webHex: "#CECBF6"))
            case .green: (Color(webHex: "#085041"), Color(webHex: "#9FE1CB"))
            case .coral: (Color(webHex: "#712B13"), Color(webHex: "#F5C4B3"))
            case .blue: (Color(webHex: "#0C447C"), Color(webHex: "#B5D4F4"))
            case .pink: (Color(webHex: "#72243E"), Color(webHex: "#F4C0D1"))
            case .gray: (Color(webHex: "#444441"), Color(webHex: "#D3D1C7"))
            }
        }
    }
    private func tile(_ icon: String, _ tint: TileTint) -> some View {
        DiaryIcon(name: icon, size: 17).foregroundStyle(tint.colors.1).frame(width: 34, height: 34).background(tint.colors.0, in: RoundedRectangle(cornerRadius: 10))
    }
    private func settingsRow(_ icon: String, _ tint: TileTint, _ title: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = false, padded: Bool = true) -> some View {
        HStack(spacing: 12) {
            tile(icon, tint)
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
    @State private var checking = false
    @State private var verified = false
    @State private var error: String?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack { DiaryIcon(name: "key-round", size: 22).foregroundStyle(.tint); Text("TMDB").font(.title2.bold()); Spacer(); Text(verified ? "Connected" : checking ? "Checking…" : "Not connected").font(.caption).foregroundStyle(verified ? Color.green : Color.secondary) }
            Text("Posters, title details, seasons and episodes.").font(.subheadline).foregroundStyle(.secondary)
            Button(checking ? "Checking…" : "Check connection") { Task { await check() } }.buttonStyle(.glass).disabled(checking)
            if let error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
            Text("API credentials stay on your server. Use the PC app to configure or replace them.").font(.caption).foregroundStyle(.secondary)
        }.diaryPanel().padding(16) }.diaryScreenBackground().navigationTitle("TMDB").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar).task { await check() }
    }
    private func check() async { checking = true; error = nil; defer { checking = false }; do { if !store.isPreview { let _: EmptyResponse = try await store.read("/api/metadata/status") }; verified = true } catch { verified = false; self.error = error.localizedDescription } }
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
