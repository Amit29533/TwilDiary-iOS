import SwiftUI
import TwilDiaryCore

/// Simkl's page: sign in, the "Also save my activity to Simkl" switch, what's waiting, what Simkl
/// couldn't take, and "Disconnect and remove".
struct SimklSettingsView: View {
    @State private var account = SimklAccount.shared
    @State private var mirror = SimklMirror.shared
    @State private var others = TrackerPreviewStore.shared
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
            return (usage.limitReachedAt != nil ? "Daily limit reached · resumes " : "Paused until ") + wake.diaryTime() + " · " + today
        }
        return today
    }
    var body: some View {
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: ThemeStore.current.native ? 16 : 20) {
                if ThemeStore.current.native {
                    // Native: the same header and Account list as the other services' pages.
                    SettingsServiceHeader(logo: .simkl, title: "Simkl", subtitle: account.signedIn ? (account.username.map { "@" + $0 } ?? "Signed in") : "",
                                          badge: account.signedIn ? ("Connected", .good) : nil) {
                        EmptyView()
                    }
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
                                .font(.app(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                        }
                        Spacer(minLength: 4)
                        if !account.signedIn {
                            Button { Task { await signIn() } } label: {
                                Text(working ? "Opening…" : "Sign in").font(.app(size: 14, weight: .bold)).foregroundStyle(WatchStyle.ink)
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
                                Text("Also save my activity to Simkl").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                            }
                            Spacer(minLength: 4)
                            Toggle("", isOn: $account.saving).labelsHidden().tint(theme.accent).accessibilityIdentifier("simkl-saving")
                        }.padding(.horizontal, 15).frame(minHeight: 64)
                    }
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
                                        .font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary)
                                    // Where it stands: paused until a time (Simkl's daily limit or a long wait), and today's requests.
                                    Text(waitingDetail).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary)
                                    if let fraction = mirror.sendFraction { SendProgressBar(fraction: fraction).padding(.top, 4) }
                                }
                                Spacer()
                                Button("Send now") { Task { await mirror.sendNow() } }.font(.app(size: 14, weight: .semibold)).tint(theme.accent)
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
                                SettingsRow(title: "Account limits") { SettingsChevron() }
                            }.buttonStyle(.plain).accessibilityIdentifier("simkl-account-limits")))
                    } else {
                        TrackerPreviewPanel(tracker: .simkl)
                    }
                    if others.simklWaiting > 0 {
                        SettingsFootnote(text: "\(others.simklWaiting.formatted()) anime \(others.simklWaiting == 1 ? "episode is" : "episodes are") still being matched with Simkl’s entries, a few shows at a time. They’re left out of the comparison until then.")
                    }
                    if !ThemeStore.current.native {
                        NavigationLink { ServiceLimitsView(tracker: .simkl) } label: {
                            SettingsRow(title: "Account limits") { SettingsChevron() }
                                .modifier(SettingsCard())
                        }.buttonStyle(.plain).accessibilityIdentifier("simkl-account-limits")
                    }
                }
                if !mirror.notKept.isEmpty {
                    SettingsGroup(label: "Not kept on Simkl") {
                        ForEach(Array(mirror.notKept.prefix(30).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                Text(item.reason).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                                if let reply = item.reply, !reply.isEmpty {
                                    // Simkl's own answer, for a closer look, folded away.
                                    DisclosureGroup("Simkl’s answer") {
                                        Text(reply).font(.app(size: 11, design: .monospaced)).foregroundStyle(HomeStyle.secondary).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.app(size: 12)).tint(HomeStyle.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 10)
                        }
                        SettingsDivider()
                        HStack {
                            Button("Try again") { Task { await mirror.retryNotKept() } }.font(.app(size: 14, weight: .semibold)).tint(theme.accent)
                                .frame(maxWidth: .infinity, minHeight: 48).disabled(!account.canSend || mirror.sending)
                            Button("Clear this list") { mirror.clearNotKept() }.font(.app(size: 14, weight: .semibold)).tint(theme.accent)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }
                }
                if !mirror.filedDifferently.isEmpty {
                    SettingsGroup(label: "Check on Simkl") {
                        ForEach(Array(mirror.filedDifferently.prefix(20).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.app(size: 14, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                                Text(item.reason).font(.app(size: 12)).foregroundStyle(HomeStyle.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 10)
                        }
                        SettingsDivider()
                        Button("Clear this list") { mirror.clearFiledDifferently() }.font(.app(size: 14, weight: .semibold)).tint(theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                if let message { SettingsFootnote(text: message) }
                if account.signedIn || !mirror.queue.jobs.isEmpty || !mirror.notKept.isEmpty {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Text("Disconnect and remove").font(.app(size: ThemeStore.current.native ? 17 : 15, weight: ThemeStore.current.native ? .regular : .semibold))
                            .frame(maxWidth: .infinity, minHeight: ThemeStore.current.native ? 52 : 50)
                    }.buttonStyle(.plain).foregroundStyle(.red).cardSurface(16)
                        .accessibilityIdentifier("simkl-remove")
                    SettingsFootnote(text: "Signs out and deletes everything TwilDiary kept for Simkl on this iPhone. Nothing on Simkl changes.")
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("Simkl").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .confirmationDialog("Disconnect Simkl and remove what TwilDiary kept for it?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Disconnect and remove", role: .destructive) { account.removeEverything(); message = "Simkl is disconnected and removed from this iPhone." }
            }
            .task { await mirror.resume() }
    }

    private func signIn() async {
        working = true; message = nil
        defer { working = false }
        do {
            if try await account.signIn(using: webSession) { message = "Signed in. Turn on “Also save my activity to Simkl” to start." }
        } catch { message = FriendlyError.message(error) }
    }
}
