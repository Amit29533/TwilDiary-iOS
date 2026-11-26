import SwiftUI

/// Settings → JellySpace → Server: the Jellyfin server run from the phone. The server's status,
/// what's playing on it, its tasks and its libraries. It works with the server's API key (which
/// has every administrator right) or a signed-in administrator.
enum JellyAdminRoute: Hashable { case tasks, libraries }

@MainActor enum JellyAdmin {
    /// The server's API key where one is set (a signed-in user may not be an administrator), else
    /// the signed-in user.
    static var client: JellyfinClient? {
        guard let base = JellyfinSettings.address else { return nil }
        if let key = JellyfinSettings.apiKey, !key.isEmpty { return JellyfinClient(base: base, key: key) }
        return JellySpace.client
    }
    nonisolated static let notAdmin = "This needs a Jellyfin administrator. Add the server's API key in Settings → JellySpace."
    /// The reason to show: a refused key (a signed-in user who isn't an administrator) says so.
    static func reason(_ error: Error) -> String {
        let text = FriendlyError.message(error)
        return text.contains("rejected") || text.contains("401") || text.contains("403") ? notAdmin : text
    }

    /// "2 min ago", "Yesterday" for a time Jellyfin gives (seven decimal places, so read to the second).
    static func ago(_ utc: String?) -> String? {
        guard let utc, utc.count >= 19, !utc.hasPrefix("0001") else { return nil }
        guard let date = ISO8601DateFormatter().date(from: String(utc.prefix(19)) + "Z") else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

// MARK: The server's admin calls

extension JellyfinClient {
    struct AdminInfo: Decodable, Sendable {
        let ServerName: String?
        let Version: String?
        let HasUpdateAvailable: Bool?
        let HasPendingRestart: Bool?
    }
    struct AdminSession: Decodable, Sendable, Identifiable {
        struct NowPlaying: Decodable, Sendable {
            let Name: String?
            let SeriesName: String?
            let IndexNumber: Int?
            let ParentIndexNumber: Int?
            let RunTimeTicks: Int64?
        }
        struct PlayState: Decodable, Sendable {
            let PositionTicks: Int64?
            let IsPaused: Bool?
            let PlayMethod: String?
        }
        struct Transcoding: Decodable, Sendable {
            let IsVideoDirect: Bool?
            let Height: Int?
            let TranscodeReasons: [String]?
        }
        let Id: String
        let UserName: String?
        let Client: String?
        let DeviceName: String?
        let NowPlayingItem: NowPlaying?
        let PlayState: PlayState?
        let TranscodingInfo: Transcoding?
        var id: String { Id }
    }
    struct AdminTask: Decodable, Sendable, Identifiable {
        struct Result: Decodable, Sendable {
            let EndTimeUtc: String?
            let Status: String?
        }
        let Id: String
        let Name: String?
        let Key: String?
        let State: String?
        let CurrentProgressPercentage: Double?
        let Category: String?
        let IsHidden: Bool?
        let LastExecutionResult: Result?
        var id: String { Id }
        var running: Bool { State == "Running" || State == "Cancelling" }
    }
    struct FolderStorage: Decodable, Sendable {
        let Path: String?
        let FreeSpace: Int64?
        let UsedSpace: Int64?
        let DeviceId: String?
    }
    struct LibraryStorage: Decodable, Sendable { let Folders: [FolderStorage]? }
    struct SystemStorage: Decodable, Sendable { let Libraries: [LibraryStorage]? }

    func adminInfo() async throws -> AdminInfo { try await get("System/Info") }
    /// Every device seen in the last quarter of an hour (the playing ones carry what they play).
    func adminSessions() async throws -> [AdminSession] {
        try await get("Sessions", [URLQueryItem(name: "activeWithinSeconds", value: "960")])
    }
    func adminTasks() async throws -> [AdminTask] {
        try await get("ScheduledTasks", [URLQueryItem(name: "isHidden", value: "false")])
    }
    /// The disks the libraries are on (Jellyfin 10.10 and later).
    func adminStorage() async throws -> SystemStorage { try await get("System/Info/Storage") }
    func runTask(_ id: String) async throws { try await post("ScheduledTasks/Running/\(id)", [], body: nil) }
    func stopTask(_ id: String) async throws { try await post("ScheduledTasks/Running/\(id)", [], body: nil, method: "DELETE") }
    func scanAllLibraries() async throws { try await post("Library/Refresh", [], body: nil) }
    /// One library looked through again for new and changed files (the dashboard's Scan library).
    func scanLibrary(_ id: String) async throws {
        try await post("Items/\(id)/Refresh", [URLQueryItem(name: "Recursive", value: "true"),
                                               URLQueryItem(name: "metadataRefreshMode", value: "Default"),
                                               URLQueryItem(name: "imageRefreshMode", value: "Default"),
                                               URLQueryItem(name: "replaceAllMetadata", value: "false"),
                                               URLQueryItem(name: "replaceAllImages", value: "false")], body: nil)
    }
    /// How many items of these types are under a library (the count alone; nothing is downloaded).
    func adminCount(parent: String, types: String) async throws -> Int {
        let page: Page = try await get("Items", [URLQueryItem(name: "ParentId", value: parent), URLQueryItem(name: "Recursive", value: "true"),
                                                 URLQueryItem(name: "IncludeItemTypes", value: types), URLQueryItem(name: "Limit", value: "0")])
        return page.TotalRecordCount
    }
    /// The libraries with all their options, as the server's own JSON (it's sent back whole when an
    /// option changes, so nothing this app doesn't know about is lost).
    func virtualFoldersJSON() async throws -> Data {
        var request = URLRequest(url: base.appending(path: "Library/VirtualFolders"), timeoutInterval: 20)
        request.setValue(JellyDevice.header + ", Token=\"\(key)\"", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw APIError.message(JellyAdmin.notAdmin) }
        guard (200..<300).contains(status) else { throw APIError.message("Jellyfin answered \(status).") }
        return data
    }
    /// A library's options saved (`body`: {"Id": …, "LibraryOptions": {…}} as JSON).
    func saveLibraryOptions(_ body: Data) async throws {
        var request = URLRequest(url: base.appending(path: "Library/VirtualFolders/LibraryOptions"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(JellyDevice.header + ", Token=\"\(key)\"", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.message("Jellyfin answered \(status).") }
    }
}

// MARK: The Server page

/// Settings → JellySpace → Server: status, four counts, what's playing, a task running, and the
/// Tasks and Libraries pages. The live part reads again every five seconds while it's open.
struct JellyServerGroups: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var client: JellyfinClient? = JellyAdmin.client
    @State private var info: JellyfinClient.AdminInfo?
    @State private var sessions: [JellyfinClient.AdminSession] = []
    @State private var tasks: [JellyfinClient.AdminTask] = []
    @State private var libraries: Int?
    @State private var storage: Double?
    @State private var failure: String?

    private var playing: [JellyfinClient.AdminSession] { sessions.filter { $0.NowPlayingItem != nil } }
    private var converting: Int { playing.filter { $0.PlayState?.PlayMethod == "Transcode" }.count }
    private var running: [JellyfinClient.AdminTask] { tasks.filter(\.running) }

    var body: some View {
        Group {
            if let failure, info == nil {
                RetryNotice(message: failure) { Task { await load() } }
            } else if let info {
                status(info)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    tile("Streams", "\(playing.count)")
                    tile("Converting", "\(converting)")
                    tile("Libraries", libraries.map { "\($0)" } ?? "–")
                    tile("Storage", storage.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                }
                if !playing.isEmpty {
                    SettingsGroup(label: "Now playing") {
                        ForEach(Array(playing.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { SettingsDivider() }
                            JellyAdminSessionRow(session: session, accent: theme.accent)
                        }
                    }
                }
                if !running.isEmpty {
                    SettingsGroup(label: "Running") {
                        ForEach(Array(running.enumerated()), id: \.element.id) { index, task in
                            if index > 0 { SettingsDivider() }
                            JellyAdminTaskProgress(task: task, accent: theme.accent)
                        }
                    }
                }
                SettingsGroup {
                    JellyAdminLink(title: "Tasks", symbol: "checklist", route: .tasks)
                    SettingsDivider()
                    JellyAdminLink(title: "Libraries", symbol: "books.vertical", route: .libraries)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await loadLive()
            }
        }
    }

    private func status(_ info: JellyfinClient.AdminInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(info.ServerName ?? "Jellyfin").font(.app(size: 22, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
            HStack(spacing: 8) {
                chip("Online", color: .green)
                if let version = info.Version { Text(version).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary) }
                if info.HasUpdateAvailable == true { chip("Update available", color: .orange) }
                if info.HasPendingRestart == true { chip("Restart needed", color: .orange) }
            }
        }.accessibilityElement(children: .combine)
    }
    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(.app(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).frame(height: 24).background(color.opacity(0.16), in: Capsule())
    }
    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
            Text(value).font(.app(size: 24, weight: .bold)).foregroundStyle(HomeStyle.primary).monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let client else { failure = "Add your Jellyfin server in Settings → JellySpace first."; return }
        failure = nil
        do {
            async let foundInfo = client.adminInfo()
            async let folders = client.virtualFoldersJSON()
            async let disks = try? client.adminStorage()
            let (read, list) = try await (foundInfo, folders)
            info = read
            libraries = ((try? JSONSerialization.jsonObject(with: list)) as? [Any])?.count
            storage = Self.usedFraction(await disks)
            await loadLive()
        } catch {
            failure = JellyAdmin.reason(error)
        }
    }
    private func loadLive() async {
        guard let client else { return }
        async let foundSessions = try? client.adminSessions()
        async let foundTasks = try? client.adminTasks()
        let (readSessions, readTasks) = await (foundSessions, foundTasks)
        withAnimation(.smooth(duration: 0.3)) {
            if let readSessions { sessions = readSessions }
            if let readTasks { tasks = readTasks }
        }
    }
    /// Used over the whole of each disk the libraries are on (each disk once).
    static func usedFraction(_ storage: JellyfinClient.SystemStorage?) -> Double? {
        var disks: [String: (used: Int64, free: Int64)] = [:]
        for folder in (storage?.Libraries ?? []).flatMap({ $0.Folders ?? [] }) {
            guard let used = folder.UsedSpace, let free = folder.FreeSpace, used + free > 0 else { continue }
            disks[folder.DeviceId ?? folder.Path ?? UUID().uuidString] = (used, free)
        }
        let used = disks.values.reduce(Int64(0)) { $0 + $1.used }, total = disks.values.reduce(Int64(0)) { $0 + $1.used + $1.free }
        return total > 0 ? Double(used) / Double(total) : nil
    }
}

/// A device playing: what, who and where, how it's sent (direct, or converted and why), and how far in.
private struct JellyAdminSessionRow: View {
    let session: JellyfinClient.AdminSession
    let accent: Color
    var body: some View {
        let item = session.NowPlayingItem
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.app(size: 17)).foregroundStyle(HomeStyle.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(item)).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Text(detail).font(.app(size: 12)).foregroundStyle(converted ? Color.orange : HomeStyle.secondary).lineLimit(1)
                if let progress { ProgressView(value: progress).tint(accent).padding(.top, 2) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11).accessibilityElement(children: .combine)
    }
    private var converted: Bool { session.PlayState?.PlayMethod == "Transcode" }
    private var symbol: String {
        let name = ((session.DeviceName ?? "") + " " + (session.Client ?? "")).lowercased()
        if name.contains("tv") || name.contains("roku") || name.contains("fire") || name.contains("shield") { return "tv" }
        if name.contains("ipad") || name.contains("tablet") { return "ipad" }
        if name.contains("web") || name.contains("chrome") || name.contains("firefox") || name.contains("safari") || name.contains("mac") || name.contains("windows") { return "desktopcomputer" }
        return "iphone"
    }
    private func title(_ item: JellyfinClient.AdminSession.NowPlaying?) -> String {
        guard let item else { return "" }
        if let series = item.SeriesName {
            let number = [item.ParentIndexNumber.map { "S\($0)" }, item.IndexNumber.map { "E\($0)" }].compactMap { $0 }.joined()
            return number.isEmpty ? series : series + " · " + number
        }
        return item.Name ?? "Something"
    }
    private var detail: String {
        var parts = [session.UserName, session.DeviceName].compactMap { $0 }
        if session.PlayState?.IsPaused == true { parts.append("Paused") }
        switch session.PlayState?.PlayMethod {
        case "Transcode":
            let height = session.TranscodingInfo?.Height.map { $0 >= 2000 ? "4K" : "\($0)p" }
            let reason = session.TranscodingInfo?.TranscodeReasons?.first.map(Self.reason)
            parts.append((["Converting", height].compactMap { $0 }.joined(separator: " ")) + (reason.map { " (\($0))" } ?? ""))
        case "DirectStream": parts.append("Direct stream")
        default: parts.append("Direct")
        }
        return parts.joined(separator: " · ")
    }
    private var progress: Double? {
        guard let total = session.NowPlayingItem?.RunTimeTicks, total > 0, let at = session.PlayState?.PositionTicks else { return nil }
        return min(1, max(0, Double(at) / Double(total)))
    }
    /// "VideoCodecNotSupported" → "video codec not supported".
    static func reason(_ raw: String) -> String {
        var words: [String] = [], current = ""
        for character in raw {
            if character.isUppercase, !current.isEmpty { words.append(current); current = "" }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ").lowercased()
    }
}

/// A task running: its name and how far it's got.
private struct JellyAdminTaskProgress: View {
    let task: JellyfinClient.AdminTask
    let accent: Color
    var body: some View {
        let percent = task.CurrentProgressPercentage ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.Name ?? "Task").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                Spacer(minLength: 8)
                Text(task.State == "Cancelling" ? "Stopping" : "\(Int(percent.rounded()))%").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
            }
            ProgressView(value: min(100, max(0, percent)), total: 100).tint(accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).accessibilityElement(children: .combine)
    }
}

private struct JellyAdminLink: View {
    let title: String
    let symbol: String
    let route: JellyAdminRoute
    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.app(size: 16, weight: .medium)).foregroundStyle(HomeStyle.chipText)
                    .frame(width: 34, height: 34).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
                Text(title).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                Spacer(minLength: 4)
                SettingsChevron()
            }
            .settingsRowFrame().contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("jellyspace-server-" + title.lowercased())
    }
}

// MARK: Tasks

/// The server's scheduled tasks by category: when each last ran (and whether it failed), Run, and
/// Stop while one runs. Reads again every three seconds while open.
struct JellyAdminTasksPage: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var client: JellyfinClient? = JellyAdmin.client
    @State private var tasks: [JellyfinClient.AdminTask]?
    @State private var failure: String?
    @State private var asked: Set<String> = []

    var body: some View {
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let tasks {
                    let categories = Dictionary(grouping: tasks, by: { $0.Category ?? "Other" })
                    ForEach(categories.keys.sorted(), id: \.self) { category in
                        SettingsGroup(label: category) {
                            let list = (categories[category] ?? []).sorted { ($0.Name ?? "") < ($1.Name ?? "") }
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, task in
                                if index > 0 { SettingsDivider() }
                                row(task)
                            }
                        }
                    }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("Tasks")
        .jellyFaceLock().jellyPage()
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private func row(_ task: JellyfinClient.AdminTask) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.Name ?? "Task").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(2)
                if task.running {
                    ProgressView(value: min(100, max(0, task.CurrentProgressPercentage ?? 0)), total: 100).tint(theme.accent)
                } else {
                    Text(last(task)).font(.app(size: 12)).foregroundStyle(failed(task) ? Color.red : HomeStyle.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(task.running ? "Stop" : "Run") { Task { await act(task) } }
                .buttonStyle(SettingsPillButtonStyle(outlined: task.running))
                .disabled(asked.contains(task.Id) || task.State == "Cancelling")
                .accessibilityIdentifier("jellyspace-task-" + (task.Key ?? task.Id))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
    private func failed(_ task: JellyfinClient.AdminTask) -> Bool { ["Failed", "Aborted"].contains(task.LastExecutionResult?.Status ?? "") }
    private func last(_ task: JellyfinClient.AdminTask) -> String {
        guard let result = task.LastExecutionResult, let when = JellyAdmin.ago(result.EndTimeUtc) else { return "Never run" }
        switch result.Status {
        case "Failed", "Aborted": return "Failed · " + when
        case "Cancelled": return "Stopped · " + when
        default: return when.prefix(1).uppercased() + when.dropFirst()
        }
    }
    private func act(_ task: JellyfinClient.AdminTask) async {
        guard let client else { return }
        asked.insert(task.Id)
        defer { asked.remove(task.Id) }
        do {
            if task.running { try await client.stopTask(task.Id) } else { try await client.runTask(task.Id) }
            await load()
        } catch {
            failure = JellyAdmin.reason(error)
        }
    }
    private func load() async {
        guard let client else { failure = "Add your Jellyfin server in Settings → JellySpace first."; return }
        do {
            let found = try await client.adminTasks()
            withAnimation(.smooth(duration: 0.3)) { tasks = found.filter { $0.IsHidden != true } }
        } catch {
            if tasks == nil { failure = JellyAdmin.reason(error) }
        }
    }
}

// MARK: Libraries

/// The server's libraries: how much each holds, Scan for one or all, and whether Jellyfin makes
/// trickplay pictures for it (the seek previews; the Trickplay images task makes them).
struct JellyAdminLibrariesPage: View {
    private struct Library: Identifiable {
        let id: String
        let name: String
        let type: String?
        var options: [String: Any]
        var trickplay: Bool { options["EnableTrickplayImageExtraction"] as? Bool ?? false }
    }
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var client: JellyfinClient? = JellyAdmin.client
    @State private var libraries: [Library]?
    @State private var counts: [String: String] = [:]
    @State private var scan: JellyfinClient.AdminTask?
    @State private var scanned: Set<String> = []
    @State private var failure: String?
    @State private var notice: String?

    var body: some View {
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let libraries {
                    SettingsGroup {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("All libraries").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                if let scan, scan.running {
                                    ProgressView(value: min(100, max(0, scan.CurrentProgressPercentage ?? 0)), total: 100).tint(theme.accent)
                                }
                            }
                            Spacer(minLength: 8)
                            Button("Scan") { Task { await scanAll() } }.buttonStyle(SettingsPillButtonStyle())
                                .disabled(scan?.running == true).accessibilityIdentifier("jellyspace-scan-all")
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    SettingsGroup(label: "Libraries") {
                        ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                            if index > 0 { SettingsDivider() }
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.name).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                    if let count = counts[library.id] { Text(count).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary) }
                                }
                                Spacer(minLength: 8)
                                let id = library.id
                                Button(scanned.contains(id) ? "Scanning" : "Scan") { Task { await scanOne(id) } }
                                    .buttonStyle(SettingsPillButtonStyle(outlined: scanned.contains(library.id)))
                                    .disabled(scanned.contains(library.id))
                                    .accessibilityIdentifier("jellyspace-scan-" + library.id)
                            }.padding(.horizontal, 16).padding(.vertical, 12)
                        }
                    }
                    SettingsGroup(label: "Trickplay pictures") {
                        ForEach(Array(libraries.enumerated()), id: \.element.id) { index, library in
                            if index > 0 { SettingsDivider() }
                            let id = library.id
                            SettingsLine(title: library.name) {
                                Toggle("", isOn: Binding(get: { library.trickplay }, set: { on in Task { await setTrickplay(id, on) } }))
                                    .labelsHidden().tint(theme.accent).accessibilityLabel("Trickplay pictures for " + library.name)
                            }
                        }
                    }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(HomeStyle.secondary).padding(.horizontal, 4) }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("Libraries")
        .jellyFaceLock().jellyPage()
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await readScan()
            }
        }
    }

    private func load() async {
        guard let client else { failure = "Add your Jellyfin server in Settings → JellySpace first."; return }
        failure = nil
        do {
            let data = try await client.virtualFoldersJSON()
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let found = rows.compactMap { row -> Library? in
                guard let id = row["ItemId"] as? String, let name = row["Name"] as? String else { return nil }
                return Library(id: id, name: name, type: (row["CollectionType"] as? String)?.lowercased(), options: row["LibraryOptions"] as? [String: Any] ?? [:])
            }
            libraries = found
            await readScan()
            for library in found { await count(library) }
        } catch {
            failure = JellyAdmin.reason(error)
        }
    }
    /// "842 films", "182 shows", "96 albums" (other kinds: nothing).
    private func count(_ library: Library) async {
        guard let client else { return }
        let kind: (types: String, one: String, many: String)? = switch library.type {
        case "movies": ("Movie", "film", "films")
        case "tvshows": ("Series", "show", "shows")
        case "music": ("MusicAlbum", "album", "albums")
        case "homevideos", "musicvideos", nil: ("Video,Movie,MusicVideo", "video", "videos")
        default: nil
        }
        guard let kind, let total = try? await client.adminCount(parent: library.id, types: kind.types) else { return }
        counts[library.id] = total.counted(kind.one, kind.many)
    }
    /// The Scan media library task, while it runs (each library's Scan ends with it).
    private func readScan() async {
        guard let client, let tasks = try? await client.adminTasks() else { return }
        let found = tasks.first { $0.Key == "RefreshLibrary" }
        if scan?.running == true, found?.running != true { scanned = [] }
        withAnimation(.smooth(duration: 0.3)) { scan = found }
    }
    private func scanAll() async {
        guard let client else { return }
        do { try await client.scanAllLibraries(); notice = nil; try? await Task.sleep(for: .seconds(1)); await readScan() }
        catch { notice = JellyAdmin.reason(error) }
    }
    private func scanOne(_ id: String) async {
        guard let client else { return }
        scanned.insert(id)
        do { try await client.scanLibrary(id); notice = nil }
        catch { scanned.remove(id); notice = JellyAdmin.reason(error); return }
        // The scan runs on the server; the button reads Scanning for a while.
        try? await Task.sleep(for: .seconds(20))
        scanned.remove(id)
    }
    /// Trickplay on or off for one library: its options go back whole with that one changed.
    private func setTrickplay(_ id: String, _ on: Bool) async {
        guard let client, var list = libraries, let index = list.firstIndex(where: { $0.id == id }) else { return }
        let name = list[index].name
        var options = list[index].options
        options["EnableTrickplayImageExtraction"] = on
        guard let body = try? JSONSerialization.data(withJSONObject: ["Id": id, "LibraryOptions": options]) else { return }
        list[index].options = options
        libraries = list
        do {
            try await client.saveLibraryOptions(body)
            notice = on ? "\(name): the pictures are made when the Trickplay images task runs (Tasks)." : nil
        } catch {
            // Put back as it was, read again from what's on screen now.
            if var now = libraries, let at = now.firstIndex(where: { $0.id == id }) {
                now[at].options["EnableTrickplayImageExtraction"] = !on
                libraries = now
            }
            notice = JellyAdmin.reason(error)
        }
    }
}
