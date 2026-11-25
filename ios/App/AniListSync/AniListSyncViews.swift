import SwiftUI
import TwilDiaryCore

/// AniList's page under its header, laid out as Simkl's: Account (only while signed out), DIRECT
/// FROM ANILIST (Preview, what Check read and what differs), OPTIONS (Also save, Make AniList
/// match, Source of truth, Force Match, Compare with your diary, Account limits, notes, private),
/// Waiting, Not kept, and Disconnect and remove.
struct AniListSyncSection: View {
    @State private var account = AniListSyncAccount.shared
    @State private var sync = AniListSync.shared
    @Environment(DiaryStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var working = false
    @State private var message: String?
    @State private var confirmForce = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !account.signedIn {
                SettingsGroup(label: "Account") {
                    SettingsRow(title: "Not signed in") {
                        Button(working ? "Opening…" : "Sign in") { Task { await signIn() } }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                            .disabled(working).accessibilityIdentifier("anilist-sync-sign-in")
                    }
                }
            } else {
                directPanel
                optionsGroup
            }
            if !sync.waiting.isEmpty || sync.lastProblem != nil {
                SettingsGroup(label: "Waiting") {
                    SettingsRow(title: sync.sending ? "Sending \(sync.waiting.count.formatted())…" : "\(sync.waiting.count.formatted()) waiting",
                                subtitle: sync.lastProblem) {
                        Button("Send now") { Task { await sync.resume(store: store) } }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                            .disabled(sync.sending || !account.canSend)
                    }
                    if let progress = sync.progress, progress.total > 0 {
                        SendProgressBar(fraction: Double(progress.done) / Double(progress.total)).padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
            }
            if !sync.notKept.isEmpty {
                SettingsGroup(label: "Not kept on AniList") {
                    ForEach(Array(sync.notKept.prefix(30).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { SettingsDivider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            Text(item.reason).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    SettingsDivider()
                    Button("Clear this list") { sync.clearNotKept() }.font(.app(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            if let message { SettingsFootnote(text: message) }
            if account.signedIn || !sync.waiting.isEmpty || !sync.notKept.isEmpty {
                Button(role: .destructive) { confirmRemove = true } label: {
                    Text("Disconnect and remove").font(.app(size: 17)).frame(maxWidth: .infinity, minHeight: 52)
                }.buttonStyle(.plain).foregroundStyle(.red).cardSurface(16).accessibilityIdentifier("anilist-sync-remove")
                SettingsFootnote(text: "Signs out and deletes everything TwilDiary kept for AniList on this iPhone. Nothing on AniList changes.")
            }
        }
        .task { await sync.resume(store: store) }
        .confirmationDialog(account.aniListWins ? "Bring AniList into your diary?" : "Make AniList exactly like your diary?", isPresented: $confirmForce, titleVisibility: .visible) {
            Button("Force Match", role: account.aniListWins ? nil : .destructive) { sync.forceMatch(store: store) }
        } message: {
            Text(forceMessage)
        }
        .confirmationDialog("Disconnect AniList and remove what TwilDiary kept for it?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Disconnect and remove", role: .destructive) { account.removeEverything(); message = "AniList is disconnected and removed from this iPhone. Nothing on AniList changed." }
        }
    }

    // MARK: Direct from AniList (as Simkl's card)

    private var directPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabel(text: "Direct from AniList") {
                SettingsBadge(text: "Preview", tone: .configured)
            }
            VStack(alignment: .leading, spacing: 12) {
                if let progress = sync.lookupProgress, progress.total > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Looking up your anime on AniList: \(progress.done.formatted()) of \(progress.total.formatted())…")
                            .font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        SendProgressBar(fraction: Double(progress.done) / Double(progress.total))
                        Text("About two seconds a title, the first time only. Nothing is sent.").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
                    }
                } else if sync.checking {
                    Text("Reading AniList…").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                }
                if let stats = sync.readStats {
                    Text("Read in \(stats.seconds < 10 ? String(format: "%.1f", stats.seconds) : String(Int(stats.seconds))) s · \(stats.requests.counted("request", "requests")) · progress, status, scores")
                        .font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    Text(statusLine(stats)).font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
                }
                if let comparison = sync.comparison {
                    if comparison.notLookedUp > 0 {
                        Text(comparison.notLookedUp.counted("title", "titles") + " not looked up on AniList yet").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
                    }
                    if comparison.matches {
                        Label("Matches your diary: " + comparison.matching.counted("entry", "entries"), systemImage: "checkmark.seal.fill")
                            .font(.app(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
                    } else {
                        Text("\(comparison.matching.formatted()) entries match. Differences:").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        differences("Only in the diary", comparison.missing)
                        differences("Progress, status or rating", comparison.different)
                        differences("Only on AniList", comparison.onlyOnAniList)
                    }
                } else if !sync.checking {
                    Text(sync.checkProblem ?? "Tap Check to compare.").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary)
                }
                if let problem = sync.checkProblem, sync.comparison != nil {
                    Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let result = sync.lastResult {
                    Label(result, systemImage: "checkmark").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(15).modifier(SettingsCard())
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("anilist-sync-direct")
    }
    private func statusLine(_ stats: AniListSync.ReadStats) -> String {
        var parts = [stats.entries.counted("entry", "entries")]
        for (status, word) in [("COMPLETED", "completed"), ("CURRENT", "watching"), ("PLANNING", "planned"), ("PAUSED", "on hold"), ("DROPPED", "dropped")] {
            if let count = stats.byStatus[status], count > 0 { parts.append("\(count.formatted()) \(word)") }
        }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder private func differences(_ name: String, _ items: [AniListPlan.Difference]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name): \(items.count.formatted())").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                    Text("· \(item.title) — \(item.detail)").font(.app(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Options (Simkl's order)

    private var optionsGroup: some View {
        let comparison = sync.comparison
        let bringing = sync.adoptions.count
        return SettingsGroup(label: "Options") {
            Toggle(isOn: $account.saving) { SettingsRowTitle("Also save my activity to AniList", "").frame(maxWidth: .infinity, alignment: .leading) }
                .settingsRowFrame().accessibilityIdentifier("anilist-sync-saving")
            SettingsDivider()
            SettingsRow(title: "Make AniList match", subtitle: comparison.map { $0.keysToSend.isEmpty ? "Nothing to send" : $0.keysToSend.count.counted("title", "titles") + " sent from your diary" } ?? "Check first") {
                Button("Send") { sync.makeMatch(store: store) }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                    .disabled((comparison?.keysToSend.isEmpty ?? true) || sync.sending || !account.canSend)
            }.accessibilityIdentifier("anilist-sync-make-match")
            SettingsDivider()
            SettingsRow(title: "Source of truth", subtitle: account.aniListWins ? "AniList wins" : "Your diary wins") {
                Menu {
                    Picker("Source of truth", selection: $account.aniListWins) {
                        Text("Diary").tag(false)
                        Text("AniList").tag(true)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(account.aniListWins ? "AniList" : "Diary").lineLimit(1)
                        Image(systemName: "chevron.down").font(.app(size: 12, weight: .bold))
                    }.font(.app(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 16).frame(height: 40).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }.accessibilityIdentifier("anilist-sync-truth")
            }
            SettingsDivider()
            SettingsRow(title: "Force Match", subtitle: account.aniListWins ? (comparison == nil ? "Bring AniList into your diary" : bringing.counted("title", "titles") + " brought into your diary") : "Make one side exactly like the other") {
                Button("Run") { confirmForce = true }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                    .disabled(comparison == nil || sync.sending || sync.checking || (account.aniListWins ? bringing == 0 : (comparison?.matches ?? true) || !account.canSend))
            }.accessibilityIdentifier("anilist-sync-force")
            SettingsDivider()
            SettingsRow(title: "Compare with your diary") {
                Button(sync.checking ? "Reading…" : "Check") { Task { await sync.check(store: store) } }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                    .disabled(sync.checking)
            }.accessibilityIdentifier("anilist-sync-compare")
            SettingsDivider()
            NavigationLink { AniListLimitsView() } label: {
                SettingsRow(title: "Account limits") { SettingsChevron() }
            }.buttonStyle(.plain).accessibilityIdentifier("anilist-account-limits")
            SettingsDivider()
            Toggle(isOn: $account.sendNotes) { SettingsRowTitle("Send my notes", "").frame(maxWidth: .infinity, alignment: .leading) }
                .settingsRowFrame().accessibilityIdentifier("anilist-sync-notes")
            SettingsDivider()
            Toggle(isOn: $account.keepPrivate) { SettingsRowTitle("Keep entries private on AniList", "").frame(maxWidth: .infinity, alignment: .leading) }
                .settingsRowFrame().accessibilityIdentifier("anilist-sync-private")
        }
    }
    private var forceMessage: String {
        if account.aniListWins {
            let items = sync.adoptions.values
            let watches = items.reduce(0) { $0 + $1.adoption.episodes.count + ($1.adoption.filmWatch == nil ? 0 : 1) }
            let names = items.prefix(3).map(\.name).joined(separator: ", ")
            return items.count.counted("title", "titles") + " take AniList’s status, score or note, and " + watches.counted("watch", "watches")
                + " are added to your diary at the time AniList last changed them (\(names)\(items.count > 3 ? ", …" : "")). Nothing is taken off your diary."
        }
        guard let comparison = sync.comparison else { return "" }
        var parts: [String] = []
        if !comparison.keysToSend.isEmpty { parts.append(comparison.keysToSend.count.counted("title", "titles") + " sent again from your diary.") }
        if !comparison.onlyOnAniList.isEmpty {
            let names = comparison.onlyOnAniList.prefix(3).map(\.title).joined(separator: ", ")
            parts.append(comparison.onlyOnAniList.count.counted("entry", "entries") + " only on AniList taken off (\(names)\(comparison.onlyOnAniList.count > 3 ? ", …" : "")). TwilDiary can’t put those back.")
        }
        return parts.joined(separator: " ")
    }

    private func signIn() async {
        working = true; message = nil
        defer { working = false }
        do {
            if try await account.signIn(using: webSession) { message = "Signed in. Turn on “Also save my activity to AniList”: your anime go on their own, about two seconds each." }
        } catch { message = FriendlyError.message(error) }
    }
}

/// AniList → Account limits: AniList's request limit, your list, the sign-in, Sign out.
struct AniListLimitsView: View {
    @State private var account = AniListSyncAccount.shared
    @State private var sync = AniListSync.shared
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 16) {
                SettingsGroup(label: "AniList", info: "AniList allows 90 requests a minute, 30 for now while its API recovers. TwilDiary sends one every two seconds, so it never hits the limit.") {
                    SettingsRow(title: "Requests", subtitle: "30 a minute for now (90 normally)") { EmptyView() }
                    SettingsDivider()
                    SettingsRow(title: "Entries on your list", subtitle: sync.readStats.map { $0.entries.formatted() } ?? "Check to count them") { EmptyView() }
                    SettingsDivider()
                    SettingsRow(title: account.username.map { "@" + $0 } ?? "Not signed in",
                                subtitle: account.expiresAt.map { "Signed in until " + $0.formatted(date: .abbreviated, time: .omitted) }) {
                        if account.signedIn {
                            Button("Sign out") { account.signOut() }.buttonStyle(SettingsPillButtonStyle(outlined: true)).lineLimit(1)
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("Account limits").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
