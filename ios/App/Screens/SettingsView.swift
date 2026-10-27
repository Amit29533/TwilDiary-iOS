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
                        NavigationLink(value: AppDestination.tmdb) { settingsRow("database", "TMDB", subtitle: "Posters, details, seasons and episodes", disclosure: true) }.accessibilityIdentifier("settings-tmdb")
                        Divider().padding(.leading, 58)
                        NavigationLink(value: AppDestination.trakt) { settingsRow("link-2", "Trakt", subtitle: "History, ratings and watchlist", value: summary?.status?.needsReconnect == true ? "Reconnect" : summary?.status?.connected == true ? "Connected" : "Set up", disclosure: true) }.accessibilityIdentifier("settings-trakt")
                    }
                    settingsSection("Data & backup") {
                        Button { exportDiary() } label: { settingsRow("download", "Export diary", subtitle: "Titles, progress, notes and file mappings", disclosure: true) }
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
            .task(id: store.sessionRevision) { summary = TraktController(service: makeTraktService(store: store)); await summary?.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await summary?.refresh() } } }
            .fileExporter(isPresented: $showExport, document: exportDocument, contentType: .json, defaultFilename: "TwilDiary-\(DiaryDate.day(store.now))") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
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
        VStack(alignment: .leading, spacing: 9) { Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4); VStack(spacing: 0, content: content).background(Color(webHex: "#111115"), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08))) }
    }
    private func settingsIcon(_ icon: String) -> some View { DiaryIcon(name: icon, size: 18).foregroundStyle(theme.accent).frame(width: 34, height: 34).background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }
    private func settingsRow(_ icon: String, _ title: String, subtitle: String? = nil, value: String? = nil, disclosure: Bool = false) -> some View {
        HStack(spacing: 10) { settingsIcon(icon); VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white); if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }; Spacer(minLength: 4); if let value { Text(value).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }; if disclosure { DiaryIcon(name: "chevron-right", size: 14).foregroundStyle(.secondary) } }.padding(14).frame(minHeight: 58).contentShape(Rectangle())
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
