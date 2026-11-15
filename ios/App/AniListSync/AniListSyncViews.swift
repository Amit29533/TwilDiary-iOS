import SwiftUI
import TwilDiaryCore

/// AniList's page, top to bottom as Simkl's (after the header): Account, Direct from AniList (your
/// list against the diary), Options (the switch, Make match, Force Match, Check, Send everything,
/// notes, private), what's waiting, what AniList couldn't take, and Disconnect.
struct AniListSyncSection: View {
    @State private var account = AniListSyncAccount.shared
    @State private var sync = AniListSync.shared
    @Environment(DiaryStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var working = false
    @State private var message: String?
    @State private var confirmEverything = false
    @State private var confirmForce = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsGroup(label: "Account", info: "Copies your anime activity to AniList as you log it: each season’s progress, status, score, dates, rewatches and your note. Your diary keeps every watch; AniList keeps no watch history. Nothing is sent until you turn it on.") {
                if account.signedIn {
                    SettingsRow(title: account.username.map { "@" + $0 } ?? "Signed in",
                                subtitle: account.expiresAt.map { "Signed in until " + $0.formatted(date: .abbreviated, time: .omitted) }) {
                        Button("Sign out") { account.signOut() }.buttonStyle(SettingsPillButtonStyle(outlined: true)).lineLimit(1)
                    }.accessibilityIdentifier("anilist-sync-account")
                } else {
                    SettingsRow(title: "Not signed in") {
                        Button(working ? "Opening…" : "Sign in") { Task { await signIn() } }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                            .disabled(working).accessibilityIdentifier("anilist-sync-sign-in")
                    }
                }
            }
            if account.signedIn {
                directGroup
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
                SettingsGroup(label: "Not kept on AniList", info: "AniList couldn’t take these, or TwilDiary couldn’t tell where they go. Everything else carries on.") {
                    ForEach(Array(sync.notKept.prefix(30).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { SettingsDivider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                            Text(item.reason).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    SettingsDivider()
                    Button("Clear this list") { sync.clearNotKept() }.font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            if let message { SettingsFootnote(text: message) }
            if account.signedIn || !sync.waiting.isEmpty || !sync.notKept.isEmpty {
                Button(role: .destructive) { confirmRemove = true } label: {
                    Text("Disconnect and remove").font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 52)
                }.buttonStyle(.plain).foregroundStyle(.red).cardSurface(16).accessibilityIdentifier("anilist-sync-remove")
                SettingsFootnote(text: "Signs out and deletes what TwilDiary kept for AniList on this iPhone. Your AniList list stays as it is.")
            }
        }
        .task { await sync.resume(store: store) }
        .confirmationDialog("Send your whole anime diary to AniList?", isPresented: $confirmEverything, titleVisibility: .visible) {
            Button("Send everything") { sync.sendEverything(store: store) }
        } message: {
            Text("Each anime’s seasons get their progress, status, score, dates and your note on AniList, about two seconds a title, in the background. Entries already on AniList are updated to match your diary.")
        }
        .confirmationDialog("Make AniList exactly like your diary?", isPresented: $confirmForce, titleVisibility: .visible) {
            Button("Force Match", role: .destructive) { sync.makeMatch(store: store, force: true) }
        } message: {
            Text(forceMessage)
        }
        .confirmationDialog("Disconnect AniList and remove what TwilDiary kept for it?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Disconnect and remove", role: .destructive) { account.removeEverything(); message = "AniList is disconnected and removed from this iPhone. Nothing on AniList changed." }
        }
    }

    /// DIRECT FROM ANILIST: your list against the diary, entry by entry.
    private var directGroup: some View {
        SettingsGroup(label: "Direct from AniList", info: "Reads your AniList list and compares each season’s progress, status and score with your diary. Changes nothing.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Compare your AniList list with your diary.").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary)
                if let comparison = sync.comparison, comparison.matches {
                    Label("Matches your diary: " + comparison.matching.counted("entry", "entries"), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
                } else if let comparison = sync.comparison {
                    Text("\(comparison.matching.formatted()) match. Differences:").font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                    differences("Not on AniList", comparison.missing)
                    differences("Different", comparison.different)
                    differences("Only on AniList", comparison.onlyOnAniList)
                }
                if let note = compareNote {
                    Text(note).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.accessibilityIdentifier("anilist-sync-direct")
    }
    private var compareNote: String? {
        if sync.checking { return "Reading AniList…" }
        if let problem = sync.checkProblem { return problem }
        if let comparison = sync.comparison, comparison.notLookedUp > 0 {
            return comparison.notLookedUp.counted("title", "titles") + " not looked up on AniList yet: Send everything does it."
        }
        if sync.comparison == nil { return "Tap Check to read AniList." }
        return sync.checkedAt.map { "Checked " + $0.formatted(date: .omitted, time: .shortened) }
    }
    @ViewBuilder private func differences(_ name: String, _ items: [AniListPlan.Difference]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name): \(items.count.formatted())").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { _, item in
                    Text("· \(item.title) — \(item.detail)").font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// OPTIONS: as Simkl's page.
    private var optionsGroup: some View {
        let comparison = sync.comparison
        return SettingsGroup(label: "Options") {
            Toggle(isOn: $account.saving) { SettingsRowTitle("Also save my activity to AniList", "") }
                .settingsRowFrame().accessibilityIdentifier("anilist-sync-saving")
            SettingsDivider()
            SettingsRow(title: "Make AniList match", subtitle: comparison.map { $0.keysToSend.isEmpty ? "Nothing to send" : $0.keysToSend.count.counted("title", "titles") + " sent again from your diary" } ?? "Check first") {
                Button("Send") { sync.makeMatch(store: store) }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                    .disabled((comparison?.keysToSend.isEmpty ?? true) || sync.sending || !account.canSend)
            }.accessibilityIdentifier("anilist-sync-make-match")
            SettingsDivider()
            SettingsRow(title: "Force Match", subtitle: "Make AniList exactly like your diary") {
                Button("Run") { confirmForce = true }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                    .disabled(comparison == nil || (comparison?.matches ?? true) || sync.sending || !account.canSend)
            }.accessibilityIdentifier("anilist-sync-force")
            SettingsDivider()
            SettingsRow(title: "Compare with your diary", subtitle: "Check what’s different") {
                Button(sync.checking ? "Reading…" : "Check") { Task { await sync.check(store: store) } }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                    .disabled(sync.checking)
            }.accessibilityIdentifier("anilist-sync-compare")
            SettingsDivider()
            SettingsRow(title: "Send everything", subtitle: "Your anime diary, once; about two seconds a title") {
                Button("Send") { confirmEverything = true }.buttonStyle(SettingsPillButtonStyle()).lineLimit(1)
                    .disabled(!account.saving || sync.sending)
            }.accessibilityIdentifier("anilist-sync-everything")
            SettingsDivider()
            Toggle(isOn: $account.sendNotes) { SettingsRowTitle("Send my notes", "") }
                .settingsRowFrame().accessibilityIdentifier("anilist-sync-notes")
            SettingsDivider()
            Toggle(isOn: $account.keepPrivate) { SettingsRowTitle("Keep entries private on AniList", "") }
                .settingsRowFrame().accessibilityIdentifier("anilist-sync-private")
        }
    }
    private var forceMessage: String {
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
            if try await account.signIn(using: webSession) { message = "Signed in. Turn on “Also save my activity to AniList”, then Send everything once." }
        } catch { message = error.localizedDescription }
    }
}
