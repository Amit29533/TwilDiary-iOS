import SwiftUI

// Settings → JellySpace → Server: Users, Activity and Analytics (with the API key, or a signed-in
// administrator). Field names checked against Jellyfin 12.4.0's OpenAPI.

// MARK: The calls

extension JellyfinClient {
    struct AdminUser: Decodable, Sendable, Identifiable {
        struct Policy: Decodable, Sendable {
            let IsAdministrator: Bool?
            let IsDisabled: Bool?
            let IsHidden: Bool?
            let EnableRemoteAccess: Bool?
        }
        let Id: String
        let Name: String?
        let PrimaryImageTag: String?
        let LastActivityDate: String?
        let Policy: Policy?
        var id: String { Id }
    }
    struct AdminActivity: Decodable, Sendable, Identifiable {
        let Id: Int64
        let Name: String?
        let ShortOverview: String?
        let Date: String?
        let UserId: String?
        let Severity: String?
        var id: Int64 { Id }
    }
    struct AdminActivityPage: Decodable, Sendable {
        let Items: [AdminActivity]
        let TotalRecordCount: Int
    }
    /// A film's, episode's or song's container and the codecs of its tracks.
    struct AdminFormatItem: Decodable, Sendable {
        struct Stream: Decodable, Sendable {
            let kind: String?
            let Codec: String?
            enum CodingKeys: String, CodingKey { case kind = "Type", Codec }
        }
        let Container: String?
        let MediaStreams: [Stream]?
    }
    struct AdminFormatPage: Decodable, Sendable {
        let Items: [AdminFormatItem]
        let TotalRecordCount: Int
    }

    func adminUsers() async throws -> [AdminUser] { try await get("Users") }
    /// A user's picture (Jellyfin serves pictures without a key).
    func adminUserImage(_ user: AdminUser) -> URL? {
        guard let tag = user.PrimaryImageTag else { return nil }
        var components = URLComponents(url: base.appending(path: "Users/\(user.Id)/Images/Primary"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "tag", value: tag), URLQueryItem(name: "fillHeight", value: "120"), URLQueryItem(name: "quality", value: "90")]
        return components?.url
    }
    /// The server's log, newest first. `system`: nil for all, true for the server's own events, false
    /// for people's; `severity`: "Warning", "Error" or nil; `user`: one user's name, or nil.
    func adminActivity(start: Int, limit: Int, system: Bool?, severity: String?, user: String?) async throws -> AdminActivityPage {
        var query = [URLQueryItem(name: "startIndex", value: String(start)), URLQueryItem(name: "limit", value: String(limit))]
        if let system { query.append(URLQueryItem(name: "hasUserId", value: system ? "false" : "true")) }
        if let severity { query.append(URLQueryItem(name: "severity", value: severity)) }
        if let user { query.append(URLQueryItem(name: "username", value: user)) }
        return try await get("System/ActivityLog/Entries", query)
    }
    /// One page of films, episodes, videos and songs with their containers and track codecs.
    func adminFormats(parent: String?, start: Int, limit: Int) async throws -> AdminFormatPage {
        var query = [URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video,MusicVideo,Audio"),
                     URLQueryItem(name: "Fields", value: "MediaStreams"), URLQueryItem(name: "EnableImages", value: "false"),
                     URLQueryItem(name: "EnableUserData", value: "false"),
                     URLQueryItem(name: "StartIndex", value: String(start)), URLQueryItem(name: "Limit", value: String(limit))]
        if let parent { query.append(URLQueryItem(name: "ParentId", value: parent)) }
        return try await get("Items", query)
    }
    /// How many items of these types are on the server (or under `parent`), the count alone.
    func adminItemCount(types: String, parent: String? = nil) async throws -> Int {
        var query = [URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "IncludeItemTypes", value: types), URLQueryItem(name: "Limit", value: "0")]
        if let parent { query.append(URLQueryItem(name: "ParentId", value: parent)) }
        let page: Page = try await get("Items", query)
        return page.TotalRecordCount
    }
    /// A request as the server's own JSON: read (`body` nil) or sent.
    func adminRaw(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(JellyDevice.header + ", Token=\"\(key)\"", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw APIError.message(JellyAdmin.notAdmin) }
        guard (200..<300).contains(status) else { throw APIError.message("Jellyfin answered \(status).") }
        return data
    }
}

@MainActor extension JellyAdmin {
    /// A Jellyfin time ("2026-11-26T10:12:13.1234567Z") as a date, read to the second.
    static func date(_ utc: String?) -> Date? {
        guard let utc, utc.count >= 19, !utc.hasPrefix("0001") else { return nil }
        return DateParsers.internet.date(from: String(utc.prefix(19)) + "Z")
    }
}

// MARK: Users

/// The server's users: picture, name, last activity and their Admin, Remote access, Hidden and
/// Disabled marks; Disable (or Enable) and Delete, each asked first; Add user.
struct JellyAdminUsersPage: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var client: JellyfinClient? = JellyAdmin.client
    @State private var users: [JellyfinClient.AdminUser]?
    @State private var failure: String?
    @State private var notice: String?
    @State private var search = ""
    @State private var confirmDisable: JellyfinClient.AdminUser?
    @State private var confirmDelete: JellyfinClient.AdminUser?
    @State private var adding = false
    @State private var busy: String?

    private var shown: [JellyfinClient.AdminUser] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = (users ?? []).sorted { ($0.Name ?? "").localizedCaseInsensitiveCompare($1.Name ?? "") == .orderedAscending }
        return query.isEmpty ? all : all.filter { ($0.Name ?? "").lowercased().contains(query) }
    }

    var body: some View {
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 18) {
                if users != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(HomeStyle.secondary)
                        TextField("Search users", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14).frame(height: 44).modifier(SettingsCard())
                    ForEach(shown) { user in row(user) }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(HomeStyle.secondary).padding(.horizontal, 4) }
                } else if let failure {
                    RetryNotice(message: failure) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("Users")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Add user").accessibilityIdentifier("jellyspace-add-user")
            }
        }
        .jellyFaceLock().jellyPage()
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(confirmDisable.map { ($0.Policy?.IsDisabled == true ? "Enable " : "Disable ") + ($0.Name ?? "this user") + "?" } ?? "",
                            isPresented: Binding(get: { confirmDisable != nil }, set: { if !$0 { confirmDisable = nil } }), titleVisibility: .visible) {
            if let user = confirmDisable {
                Button(user.Policy?.IsDisabled == true ? "Enable" : "Disable", role: user.Policy?.IsDisabled == true ? nil : .destructive) {
                    Task { await setDisabled(user, user.Policy?.IsDisabled != true) }
                }
            }
        } message: {
            if confirmDisable?.Policy?.IsDisabled != true { Text("They can't sign in until enabled again.") }
        }
        .confirmationDialog(confirmDelete.map { "Delete " + ($0.Name ?? "this user") + "?" } ?? "",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            if let user = confirmDelete {
                Button("Delete", role: .destructive) { Task { await delete(user) } }
            }
        } message: {
            Text("Their account, watch progress and settings on this server go for good. This can't be undone.")
        }
        .sheet(isPresented: $adding) {
            JellyAdminAddUser { name, password in await add(name, password) }
        }
    }

    private func row(_ user: JellyfinClient.AdminUser) -> some View {
        let policy = user.Policy
        let disabled = policy?.IsDisabled == true
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                avatar(user)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.Name ?? "User").font(.app(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Text(JellyAdmin.date(user.LastActivityDate).map { "Last activity " + DateParsers.relative.localizedString(for: $0, relativeTo: .now) } ?? "No activity yet")
                        .font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if policy?.IsAdministrator == true { mark("Admin", "shield.fill", theme.accent) }
                if policy?.EnableRemoteAccess == true { mark("Remote access", "network", theme.accent) }
                if policy?.IsHidden == true { mark("Hidden", "eye.slash", HomeStyle.secondary) }
                if disabled { mark("Disabled", "nosign", .red) }
            }
            HStack(spacing: 10) {
                Button(disabled ? "Enable" : "Disable") { confirmDisable = user }
                    .buttonStyle(SettingsPillButtonStyle(outlined: true)).disabled(busy == user.Id)
                    .accessibilityIdentifier("jellyspace-user-disable-" + user.Id)
                Button("Delete", role: .destructive) { confirmDelete = user }
                    .buttonStyle(SettingsPillButtonStyle(outlined: true)).disabled(busy == user.Id)
                    .accessibilityIdentifier("jellyspace-user-delete-" + user.Id)
                if busy == user.Id { ProgressView() }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
        .opacity(disabled ? 0.7 : 1)
    }
    private func avatar(_ user: JellyfinClient.AdminUser) -> some View {
        let initial = String((user.Name ?? "?").prefix(1)).uppercased()
        return ZStack {
            Circle().fill(theme.accent.opacity(0.85))
            Text(initial).font(.app(size: 18, weight: .bold)).foregroundStyle(.white)
            if let url = client?.adminUserImage(user) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }
        .frame(width: 48, height: 48).clipShape(Circle()).accessibilityHidden(true)
    }
    private func mark(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(.app(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).frame(height: 26).background(color.opacity(0.14), in: Capsule())
    }

    private func load() async {
        guard let client else { failure = "Add your Jellyfin server in Settings → JellySpace first."; return }
        do { users = try await client.adminUsers(); failure = nil }
        catch { if users == nil { failure = JellyAdmin.reason(error) } else { notice = JellyAdmin.reason(error) } }
    }
    /// Disabled or enabled: the user's policy goes back whole with that one changed.
    private func setDisabled(_ user: JellyfinClient.AdminUser, _ disabled: Bool) async {
        guard let client else { return }
        busy = user.Id; defer { busy = nil }
        do {
            let data = try await client.adminRaw("Users/\(user.Id)")
            guard var policy = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["Policy"] as? [String: Any] else {
                throw APIError.message("Jellyfin didn't send this user's settings.")
            }
            policy["IsDisabled"] = disabled
            let body = try JSONSerialization.data(withJSONObject: policy)
            _ = try await client.adminRaw("Users/\(user.Id)/Policy", method: "POST", body: body)
            notice = nil
            await load()
        } catch {
            notice = JellyAdmin.reason(error)
        }
    }
    private func delete(_ user: JellyfinClient.AdminUser) async {
        guard let client else { return }
        busy = user.Id; defer { busy = nil }
        do { _ = try await client.adminRaw("Users/\(user.Id)", method: "DELETE"); notice = nil; await load() }
        catch { notice = JellyAdmin.reason(error) }
    }
    /// A new user, with a password if one was given (else they set one in Jellyfin).
    private func add(_ name: String, _ password: String) async -> String? {
        guard let client else { return "Add your Jellyfin server first." }
        var body: [String: String] = ["Name": name]
        if !password.isEmpty { body["Password"] = password }
        do {
            _ = try await client.adminRaw("Users/New", method: "POST", body: try JSONEncoder().encode(body))
            await load()
            return nil
        } catch {
            return JellyAdmin.reason(error)
        }
    }
}

/// Add user: a name, and a password (optional).
private struct JellyAdminAddUser: View {
    let create: (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var failure: String?
    @State private var working = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("jellyspace-new-user-name")
                    SecureField("Password", text: $password).textContentType(.newPassword)
                        .accessibilityIdentifier("jellyspace-new-user-password")
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .navigationTitle("Add user").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() }
                    else {
                        Button("Create") {
                            working = true
                            Task {
                                let reason = await create(name.trimmingCharacters(in: .whitespaces), password)
                                working = false
                                if let reason { failure = reason } else { dismiss() }
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: Activity

/// The server's log, newest first, under Just now, Last hour, Today, Yesterday, This week and
/// Earlier; All, People or System, a severity and one user; more as you scroll.
struct JellyAdminActivityPage: View {
    private enum Kind: String, CaseIterable { case all = "All", people = "People", system = "System" }
    private static let pageSize = 50
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var client: JellyfinClient? = JellyAdmin.client
    @State private var entries: [JellyfinClient.AdminActivity] = []
    @State private var total: Int?
    @State private var kind = Kind.all
    @State private var severity: String?
    @State private var user: String?
    @State private var users: [JellyfinClient.AdminUser] = []
    @State private var failure: String?
    @State private var loadingMore = false

    var body: some View {
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 14) {
                Picker("Kind", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                HStack(spacing: 8) {
                    Menu {
                        Picker("Severity", selection: $severity) {
                            Text("All severities").tag(String?.none)
                            Text("Warnings").tag(String?.some("Warning"))
                            Text("Errors").tag(String?.some("Error"))
                        }
                    } label: { chip(severity.map { $0 == "Error" ? "Errors" : "Warnings" } ?? "All severities", "line.3.horizontal.decrease") }
                    Menu {
                        Picker("User", selection: $user) {
                            Text("All users").tag(String?.none)
                            ForEach(users) { person in Text(person.Name ?? "User").tag(person.Name) }
                        }
                    } label: { chip(user ?? "All users", "person") }
                    Spacer(minLength: 0)
                    if let total { Text("\(entries.count.formatted()) of \(total.formatted())").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).monospacedDigit() }
                }
                if let failure, entries.isEmpty {
                    RetryNotice(message: failure) { Task { await reload() } }
                } else if total == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if entries.isEmpty {
                    Text("Nothing logged here.").font(.app(size: 14)).foregroundStyle(HomeStyle.secondary).frame(maxWidth: .infinity, minHeight: 80)
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.app(size: 13, weight: .semibold)).foregroundStyle(theme.accent).padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { SettingsDivider() }
                                row(entry).onAppear { if entry.id == entries.last?.id { Task { await loadMore() } } }
                            }
                        }.modifier(SettingsCard())
                    }
                }
                if loadingMore { ProgressView().frame(maxWidth: .infinity, minHeight: 44) }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("Activity")
        .jellyFaceLock().jellyPage()
        .task(id: "\(kind.rawValue)|\(severity ?? "")|\(user ?? "")") { await reload() }
        .task { if let client { users = (try? await client.adminUsers()) ?? [] } }
        .refreshable { await reload() }
    }

    private struct TimeGroup { let title: String; let items: [JellyfinClient.AdminActivity] }
    /// Consecutive entries in the same stretch of time, in order.
    private var groups: [TimeGroup] {
        var result: [TimeGroup] = []
        let now = Date.now, calendar = Calendar.current
        for entry in entries {
            let title: String
            if let date = JellyAdmin.date(entry.Date) {
                let age = now.timeIntervalSince(date)
                if age < 300 { title = "Just now" }
                else if age < 3600 { title = "Last hour" }
                else if calendar.isDateInToday(date) { title = "Today" }
                else if calendar.isDateInYesterday(date) { title = "Yesterday" }
                else if age < 7 * 86_400 { title = "This week" }
                else { title = "Earlier" }
            } else { title = "Earlier" }
            if result.last?.title == title { result[result.count - 1] = TimeGroup(title: title, items: result[result.count - 1].items + [entry]) }
            else { result.append(TimeGroup(title: title, items: [entry])) }
        }
        return result
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
            .padding(.horizontal, 12).frame(height: 34).overlay(Capsule().strokeBorder(HomeStyle.outline(0.3)))
    }
    private func row(_ entry: JellyfinClient.AdminActivity) -> some View {
        let (symbol, color): (String, Color) = switch entry.Severity {
        case "Warning": ("exclamationmark.triangle", .orange)
        case "Error", "Critical": ("xmark.octagon", .red)
        default: ("info.circle", theme.accent)
        }
        let name = users.first { $0.Id == entry.UserId }?.Name
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.app(size: 16)).foregroundStyle(color).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.Name ?? "Event").font(.app(size: 15, weight: .medium)).foregroundStyle(HomeStyle.primary).fixedSize(horizontal: false, vertical: true)
                if let detail = entry.ShortOverview, !detail.isEmpty {
                    Text(detail).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let name { Text(name).font(.app(size: 13)).foregroundStyle(theme.accent) }
            }
            Spacer(minLength: 8)
            if let date = JellyAdmin.date(entry.Date) {
                Text(DateParsers.relative.localizedString(for: date, relativeTo: .now)).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).accessibilityElement(children: .combine)
    }

    private func reload() async {
        guard let client else { failure = "Add your Jellyfin server in Settings → JellySpace first."; return }
        do {
            let page = try await client.adminActivity(start: 0, limit: Self.pageSize, system: system, severity: severity, user: user)
            guard !Task.isCancelled else { return }
            entries = page.Items; total = page.TotalRecordCount; failure = nil
        } catch {
            if !Task.isCancelled { failure = JellyAdmin.reason(error); if entries.isEmpty { total = 0 } }
        }
    }
    private func loadMore() async {
        guard let client, !loadingMore, let total, entries.count < total else { return }
        loadingMore = true; defer { loadingMore = false }
        let filters = (system, severity, user)
        guard let page = try? await client.adminActivity(start: entries.count, limit: Self.pageSize, system: filters.0, severity: filters.1, user: filters.2),
              filters == (system, severity, user) else { return }
        let known = Set(entries.map(\.id))
        entries += page.Items.filter { !known.contains($0.id) }
        self.total = page.TotalRecordCount
    }
    private var system: Bool? { kind == .all ? nil : kind == .system }
}

// MARK: Analytics

/// What's on the server: totals (all libraries or one), each library's share, and the containers,
/// video codecs and audio codecs of its films, episodes and songs. The formats need every item's
/// tracks, so they're read once in the background (pages of 400) and kept until read again.
struct JellyAdminAnalyticsPage: View {
    private struct Library: Identifiable, Hashable { let id: String; let name: String }
    struct Formats: Codable, Equatable {
        var containers: [String: Int] = [:]
        var video: [String: Int] = [:]
        var audio: [String: Int] = [:]
        var read = 0
        var total = 0
    }
    @MainActor private static var keptFormats: [String: Formats] = [:]
    @State private var client: JellyfinClient? = JellyAdmin.client
    @State private var libraries: [Library] = []
    @State private var library: Library?
    @State private var totals: [(String, String, Int)] = []
    @State private var shares: [(String, Int)] = []
    @State private var formats: Formats?
    @State private var reading = false
    @State private var failure: String?

    var body: some View {
        EdgeToEdgeScroll {
            LazyVStack(alignment: .leading, spacing: 18) {
                Menu {
                    Picker("Library", selection: $library) {
                        Text("All libraries").tag(Library?.none)
                        ForEach(libraries) { item in Text(item.name).tag(Library?.some(item)) }
                    }
                } label: {
                    HStack {
                        Image(systemName: "books.vertical").foregroundStyle(HomeStyle.secondary)
                        Text(library?.name ?? "All libraries").font(.app(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
                    }.padding(.horizontal, 16).frame(height: 50).modifier(SettingsCard())
                }
                if let failure, totals.isEmpty { RetryNotice(message: failure) { Task { await loadCounts() } } }
                if !totals.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        ForEach(totals.indices, id: \.self) { index in tile(totals[index].0, totals[index].1, totals[index].2) }
                    }
                }
                if library == nil, !shares.isEmpty {
                    JellyAdminBreakdown(title: "Share of items by library", rows: shares)
                }
                if let formats {
                    if reading { progress(formats) }
                    if !formats.containers.isEmpty { JellyAdminBreakdown(title: "Containers", rows: Self.top(formats.containers)) }
                    if !formats.video.isEmpty { JellyAdminBreakdown(title: "Video codecs", rows: Self.top(formats.video)) }
                    if !formats.audio.isEmpty { JellyAdminBreakdown(title: "Audio codecs", rows: Self.top(formats.audio)) }
                } else if reading {
                    progress(Formats())
                }
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
        .diaryScreenBackground().diaryPageNavigation("Analytics")
        .jellyFaceLock().jellyPage()
        .task { await loadLibraries() }
        .task(id: library?.id ?? "") {
            await loadCounts()
            await loadFormats(fresh: false)
        }
        .refreshable { await loadCounts(); await loadFormats(fresh: true) }
    }

    private func tile(_ label: String, _ symbol: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
            Text(value.formatted()).font(.app(size: 24, weight: .bold)).foregroundStyle(HomeStyle.primary).monospacedDigit()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
        .accessibilityElement(children: .combine)
    }
    private func progress(_ formats: Formats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(formats.total > 0 ? "Reading formats… \(formats.read.formatted()) of \(formats.total.formatted())" : "Reading formats…")
                .font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
            ProgressView(value: formats.total > 0 ? Double(formats.read) / Double(formats.total) : 0)
        }
        .padding(14).modifier(SettingsCard())
    }
    /// The largest five and the rest together as Other.
    static func top(_ counts: [String: Int]) -> [(String, Int)] {
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard sorted.count > 6 else { return sorted.map { ($0.key, $0.value) } }
        let rest = sorted.dropFirst(5)
        return sorted.prefix(5).map { ($0.key, $0.value) } + [("Other: " + rest.prefix(3).map(\.key).joined(separator: ", "), rest.reduce(0) { $0 + $1.value })]
    }

    private func loadLibraries() async {
        guard let client, let data = try? await client.virtualFoldersJSON(),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        libraries = rows.compactMap { row in
            guard let id = row["ItemId"] as? String, let name = row["Name"] as? String else { return nil }
            return Library(id: id, name: name)
        }
        if library == nil { await loadShares() }
    }
    private func loadCounts() async {
        guard let client else { failure = "Add your Jellyfin server in Settings → JellySpace first."; return }
        let parent = library?.id
        async let movies = try? client.adminItemCount(types: "Movie", parent: parent)
        async let series = try? client.adminItemCount(types: "Series", parent: parent)
        async let episodes = try? client.adminItemCount(types: "Episode", parent: parent)
        async let songs = try? client.adminItemCount(types: "Audio", parent: parent)
        async let photos = try? client.adminItemCount(types: "Photo", parent: parent)
        let found = await [("Movies", "film", movies), ("Series", "tv", series), ("Episodes", "play.rectangle.on.rectangle", episodes),
                           ("Songs", "music.note", songs), ("Photos", "photo", photos)]
        guard !Task.isCancelled, parent == library?.id else { return }
        if found.allSatisfy({ $0.2 == nil }) { failure = JellyAdmin.notAdmin; return }
        failure = nil
        var shown: [(String, String, Int)] = []
        for (label, symbol, count) in found { if let count, count > 0 { shown.append((label, symbol, count)) } }
        totals = shown
    }
    /// Each library's films, episodes, videos, songs, photos and books.
    private func loadShares() async {
        guard let client else { return }
        var found: [(String, Int)] = []
        for item in libraries {
            if let count = try? await client.adminItemCount(types: "Movie,Episode,Video,MusicVideo,Audio,Photo,Book", parent: item.id), count > 0 {
                found.append((item.name, count))
            }
        }
        shares = found.sorted { $0.1 > $1.1 }
    }
    /// Every item's container and first video and audio track, read once in pages and kept.
    private func loadFormats(fresh: Bool) async {
        guard let client else { return }
        let key = library?.id ?? "all"
        if !fresh, let kept = Self.keptFormats[key] { formats = kept; return }
        if !fresh, let saved = Self.saved(key) { formats = saved; Self.keptFormats[key] = saved; return }
        reading = true; defer { reading = false }
        var tally = Formats()
        formats = nil
        var start = 0
        while !Task.isCancelled {
            guard let page = try? await client.adminFormats(parent: library?.id, start: start, limit: 400) else { return }
            tally.total = page.TotalRecordCount
            for item in page.Items {
                if let container = item.Container?.split(separator: ",").first.map(String.init), !container.isEmpty {
                    tally.containers[container.uppercased(), default: 0] += 1
                }
                if let codec = item.MediaStreams?.first(where: { $0.kind == "Video" })?.Codec { tally.video[Self.codec(codec), default: 0] += 1 }
                if let codec = item.MediaStreams?.first(where: { $0.kind == "Audio" })?.Codec { tally.audio[Self.codec(codec), default: 0] += 1 }
            }
            start += page.Items.count
            tally.read = start
            formats = tally
            if page.Items.isEmpty || start >= page.TotalRecordCount { break }
        }
        guard !Task.isCancelled, key == (library?.id ?? "all") else { return }
        Self.keptFormats[key] = tally
        Self.save(tally, key)
    }
    static func codec(_ raw: String) -> String {
        switch raw.lowercased() {
        case "h264", "avc": "H.264"
        case "hevc", "h265": "HEVC"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "vp8": "VP8"
        case "mpeg4": "MPEG-4"
        case "mpeg2video": "MPEG-2"
        case "vc1": "VC-1"
        case "aac": "AAC"
        case "ac3": "AC3"
        case "eac3": "EAC3"
        case "dts": "DTS"
        case "truehd": "TrueHD"
        case "flac": "FLAC"
        case "opus": "Opus"
        case "mp3": "MP3"
        case "vorbis": "Vorbis"
        case "alac": "ALAC"
        default: raw.uppercased()
        }
    }
    private static func saved(_ key: String) -> Formats? {
        UserDefaults.standard.data(forKey: "admin.formats." + key).flatMap { try? JSONDecoder().decode(Formats.self, from: $0) }
    }
    private static func save(_ formats: Formats, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(formats), forKey: "admin.formats." + key)
    }
}

/// A titled card: one bar split by share, then each part with its colour, count and percentage.
private struct JellyAdminBreakdown: View {
    let title: String
    let rows: [(String, Int)]
    private static let colours: [Color] = [
        Color(red: 0.12, green: 0.53, blue: 0.82), Color(red: 0.85, green: 0.35, blue: 0.19), Color(red: 0.5, green: 0.47, blue: 0.87),
        Color(red: 0.73, green: 0.46, blue: 0.09), Color(red: 0.83, green: 0.33, blue: 0.49), Color(red: 0.11, green: 0.62, blue: 0.46),
        Color(white: 0.55),
    ]
    private var total: Int { rows.reduce(0) { $0 + $1.1 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
            GeometryReader { proxy in
                HStack(spacing: 1.5) {
                    ForEach(rows.indices, id: \.self) { index in
                        Rectangle().fill(Self.colour(index))
                            .frame(width: max(2, proxy.size.width * CGFloat(rows[index].1) / CGFloat(max(1, total)) - 1.5))
                    }
                }
            }
            .frame(height: 8).clipShape(Capsule())
            VStack(spacing: 10) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        Circle().fill(Self.colour(index)).frame(width: 9, height: 9)
                        Text(rows[index].0).font(.app(size: 14)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(rows[index].1.formatted()).font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).monospacedDigit()
                        Text(Self.percent(rows[index].1, of: total)).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsCard())
    }
    private static func colour(_ index: Int) -> Color { colours[min(index, colours.count - 1)] }
    private static func percent(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "" }
        return (Double(value) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
    }
}
