import SwiftUI
import TwilDiaryCore

/// Simkl's page: sign in, the "Also save my activity to Simkl" switch, what's waiting, what Simkl
/// couldn't take, and "Disconnect and remove".
struct SimklSettingsView: View {
    @State private var account = SimklAccount.shared
    @State private var mirror = SimklMirror.shared
    @State private var others = TrackerPreviewStore.shared
    @State private var notesCopy = SimklNotesCopy.shared
    @State private var confirmCopy = false
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.webAuthenticationSession) private var webSession
    @State private var working = false
    @State private var message: String?
    @State private var confirmRemove = false

    /// "Paused until 5:35 am · 590 requests today": why it is waiting and how much of the day is used.
    private var waitingDetail: String {
        let usage = SimklUsage.today()
        // Simkl's own count for the account when known ("222 of 500 today"), else TwilDiary's.
        let today = ProviderQuota.daily(host: SimklAPI.quotaHost).map { "\($0.used.formatted()) of \($0.limit.formatted()) today" }
            ?? "\(usage.count.formatted()) \(usage.count == 1 ? "request" : "requests") today"
        if let wake = mirror.queue.nextWake, wake.timeIntervalSinceNow > 600 {
            return (usage.limitReachedAt != nil ? "Daily limit reached · resumes " : "Paused until ") + wake.formatted(date: .omitted, time: .shortened) + " · " + today
        }
        return today
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeStore.current.native ? 16 : 20) {
                if ThemeStore.current.native {
                    // Native: the same header and Account list as the other services' pages.
                    SettingsServiceHeader(logo: .simkl, title: "Simkl", subtitle: account.signedIn ? (account.username.map { "@" + $0 } ?? "Signed in") : "Your activity, copied to Simkl",
                                          badge: account.signedIn ? ("Connected", .good) : nil) { EmptyView() }
                    if !account.signedIn {
                        SettingsGroup(label: "Account") {
                            SettingsRow(title: "Not signed in") {
                                Button(working ? "Opening…" : "Sign in") { Task { await signIn() } }.buttonStyle(SettingsPillButtonStyle())
                                    .disabled(working).accessibilityIdentifier("simkl-sign-in")
                            }
                        }
                    }
                } else {
                SettingsGroup(label: "Account") {
                    HStack(spacing: 14) {
                        BrandLogo(service: .simkl, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.signedIn ? (account.username.map { "@" + $0 } ?? "Signed in") : "Simkl")
                                .font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            Text(account.signedIn ? "Connected on this iPhone" : "Sign in to copy your activity to Simkl")
                                .font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                        }
                        Spacer(minLength: 4)
                        if !account.signedIn {
                            Button { Task { await signIn() } } label: {
                                Text(working ? "Opening…" : "Sign in").font(.system(size: 14, weight: .bold)).foregroundStyle(WatchStyle.ink)
                                    .padding(.horizontal, 14).frame(height: 34).background(WatchStyle.fill, in: Capsule())
                            }.buttonStyle(.plain).disabled(working).accessibilityIdentifier("simkl-sign-in")
                        }
                    }.padding(.horizontal, 15).frame(minHeight: 72)
                }
                }
                if account.signedIn {
                    if !ThemeStore.current.native {
                    SettingsGroup {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Also save my activity to Simkl").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                Text("Works when you use another service").font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                            }
                            Spacer(minLength: 4)
                            Toggle("", isOn: $account.saving).labelsHidden().tint(theme.accent).accessibilityIdentifier("simkl-saving")
                        }.padding(.horizontal, 15).frame(minHeight: 64)
                    }
                    SettingsFootnote(text: "Watches, removals, ratings and Planned, Watching, Completed, On hold and Dropped are copied as you make them, from now on. Your diary stays where it is; Simkl gets a copy.")
                    }
                    if ThemeStore.current.native, !mirror.queue.jobs.isEmpty || mirror.lastProblem != nil {
                        // Native: one row with the small button, and the bar under it.
                        SettingsGroup(label: "Waiting") {
                            SettingsRow(title: mirror.sending ? "Sending \(mirror.queue.jobs.count)…" : "\(mirror.queue.jobs.count) waiting", subtitle: waitingDetail) {
                                Button("Send now") { Task { await mirror.sendNow() } }.buttonStyle(SettingsPillButtonStyle())
                                    .disabled(mirror.sending || !account.saving)
                            }
                            if let fraction = mirror.sendFraction { SendProgressBar(fraction: fraction).padding(.horizontal, 16).padding(.bottom, 12) }
                        }
                        if let problem = mirror.lastProblem { SettingsFootnote(text: problem) }
                    } else if !mirror.queue.jobs.isEmpty || mirror.lastProblem != nil {
                        SettingsGroup(label: "Waiting") {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mirror.sending ? "Sending \(mirror.queue.jobs.count)…" : "\(mirror.queue.jobs.count) waiting")
                                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                    // Where it stands: paused until a time (Simkl's daily limit or a long wait), and today's requests.
                                    Text(waitingDetail).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary)
                                    if let fraction = mirror.sendFraction { SendProgressBar(fraction: fraction).padding(.top, 4) }
                                }
                                Spacer()
                                Button("Send now") { Task { await mirror.sendNow() } }.font(.system(size: 14, weight: .semibold)).tint(theme.accent)
                                    .disabled(mirror.sending || !account.saving)
                            }.padding(.horizontal, 15).frame(minHeight: 56)
                        }
                        if let problem = mirror.lastProblem { SettingsFootnote(text: problem) }
                    }
                    if ThemeStore.current.native {
                        TrackerPreviewPanel(tracker: .simkl, leadingOptions: AnyView(
                            Toggle(isOn: $account.saving) { SettingsRowTitle("Also save my activity to Simkl", "") }
                                .settingsRowFrame().accessibilityIdentifier("simkl-saving")), trailingOptions: AnyView(
                            NavigationLink { ServiceLimitsView(tracker: .simkl) } label: {
                                SettingsRow(title: "Account limits", subtitle: "Daily requests and your plan") { SettingsChevron() }
                            }.buttonStyle(.plain).accessibilityIdentifier("simkl-account-limits")))
                    } else {
                        TrackerPreviewPanel(tracker: .simkl)
                    }
                    if others.simklWaiting > 0 {
                        SettingsFootnote(text: "\(others.simklWaiting.formatted()) anime \(others.simklWaiting == 1 ? "episode is" : "episodes are") still being matched with Simkl’s entries, a few shows at a time. They’re left out of the comparison until then.")
                    }
                    if !ThemeStore.current.native {
                        NavigationLink { ServiceLimitsView(tracker: .simkl) } label: {
                            SettingsRow(title: "Account limits", subtitle: "Daily requests and your plan") { SettingsChevron() }
                                .modifier(SettingsCard())
                        }.buttonStyle(.plain).accessibilityIdentifier("simkl-account-limits")
                    }
                    if store.traktSignedInOnPhone && !TraktDirectStore.shared.localOnly {
                        // Simkl's memos as private Trakt notes, where Trakt has none yet.
                        SettingsGroup(label: "Notes", info: "Your Simkl notes become private notes on Trakt, only for titles with no note there yet. Nothing changes on Simkl.") {
                            SettingsRow(title: "Copy notes to Trakt", subtitle: notesCopy.progress ?? notesDetail) {
                                Button(notesCopy.running ? "Copying…" : "Copy") { confirmCopy = true }.buttonStyle(SettingsPillButtonStyle())
                                    .lineLimit(1).disabled(notesCopy.running)
                            }.accessibilityIdentifier("simkl-copy-notes")
                        }
                        if let result = notesCopy.result { SettingsFootnote(text: result) }
                    }
                }
                if !mirror.notKept.isEmpty {
                    SettingsGroup(label: "Not kept on Simkl", info: "Simkl couldn’t find these, even by air date. They aren’t sent again; the rest of your activity carries on.") {
                        ForEach(Array(mirror.notKept.prefix(30).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                Text(item.reason).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                                if let reply = item.reply, !reply.isEmpty {
                                    // Simkl's own answer, for a closer look, folded away.
                                    DisclosureGroup("Simkl’s answer") {
                                        Text(reply).font(.system(size: 11, design: .monospaced)).foregroundStyle(HomeStyle.secondary).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.system(size: 12)).tint(HomeStyle.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 10)
                        }
                        SettingsDivider()
                        HStack {
                            Button("Try again") { Task { await mirror.retryNotKept() } }.font(.system(size: 14, weight: .semibold)).tint(theme.accent)
                                .frame(maxWidth: .infinity, minHeight: 48).disabled(!account.canSend || mirror.sending)
                            Button("Clear this list") { mirror.clearNotKept() }.font(.system(size: 14, weight: .semibold)).tint(theme.accent)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }
                }
                if !mirror.filedDifferently.isEmpty {
                    SettingsGroup(label: "Check on Simkl", info: "Simkl took these, but filed them as the other kind (a show sent as a movie, or the reverse), so it may have taken another title.") {
                        ForEach(Array(mirror.filedDifferently.prefix(20).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                Text(item.reason).font(.system(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 10)
                        }
                        SettingsDivider()
                        Button("Clear this list") { mirror.clearFiledDifferently() }.font(.system(size: 14, weight: .semibold)).tint(theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                if let message { SettingsFootnote(text: message) }
                if account.signedIn || !mirror.queue.jobs.isEmpty || !mirror.notKept.isEmpty {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Text("Disconnect and remove").font(.system(size: ThemeStore.current.native ? 17 : 15, weight: ThemeStore.current.native ? .regular : .semibold))
                            .frame(maxWidth: .infinity, minHeight: ThemeStore.current.native ? 52 : 50)
                    }.buttonStyle(.plain).foregroundStyle(.red).cardSurface(16)
                        .accessibilityIdentifier("simkl-remove")
                    SettingsFootnote(text: "Signs out and deletes everything TwilDiary kept for Simkl on this iPhone. Nothing on Simkl changes.")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }.diaryScreenBackground().diaryPageNavigation("Simkl")
            .confirmationDialog("Copy your Simkl notes to Trakt?", isPresented: $confirmCopy, titleVisibility: .visible) {
                Button("Copy notes") { Task { await notesCopy.run(store: store) } }
            } message: {
                Text("Simkl and Trakt are read first. Each note goes to Trakt as a private note, only for titles with no note there; nothing on Simkl changes.")
            }
            .confirmationDialog("Disconnect Simkl and remove what TwilDiary kept for it?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Disconnect and remove", role: .destructive) { account.removeEverything(); message = "Simkl is disconnected and removed from this iPhone." }
            }
            .task { await mirror.resume() }
    }

    /// "12 on Simkl · 9 not on Trakt yet", from the last reads.
    private var notesDetail: String {
        guard let count = notesCopy.onSimkl else { return "Reads your Simkl notes first" }
        let missing = notesCopy.plan.send.count
        return "\(count.formatted()) on Simkl · " + (missing == 0 ? "all on Trakt" : "\(missing.formatted()) not on Trakt yet")
    }

    private func signIn() async {
        working = true; message = nil
        defer { working = false }
        do {
            if try await account.signIn(using: webSession) { message = "Signed in. Turn on “Also save my activity to Simkl” to start." }
        } catch { message = error.localizedDescription }
    }
}
