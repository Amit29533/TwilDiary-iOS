import SwiftUI
import TwilDiaryCore

@MainActor struct TraktView: View {
    let store: DiaryStore
    @State private var controller: TraktController
    @State private var incoming: IncomingTraktController
    @State private var showSignIn = false
    @State private var clock = Date.now
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("traktGrid") private var grid = false
    init(store: DiaryStore) {
        self.store = store
        _controller = State(initialValue: store.traktController)
        _incoming = State(initialValue: IncomingTraktController(service: makeIncomingTraktService(store: store)))
    }
    var body: some View {
        @Bindable var controller = controller
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                connection
                if controller.restoringApproval { restoringImport }
                if controller.status?.connected == true {
                    preferences
                    incomingWatches
                    if controller.sync?.run?.state == "building" { scanProgress }
                    if let sync = controller.sync, sync.run != nil {
                        if sync.reviewing || sync.run?.state == "complete" { transferProgress(sync) }
                        review(sync)
                    }
                }
                if let error = controller.error { VStack(alignment: .leading, spacing: 8) { Text(error).font(.subheadline).foregroundStyle(.secondary); Button("Retry") { Task { await controller.refresh() } }.disabled(controller.busy) }.diaryPanel().accessibilityIdentifier("trakt-error") }
            }.padding(16).padding(.bottom, 100)
        }.diaryScreenBackground().navigationTitle("Trakt").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task(id: controller.kind.rawValue + "\n" + controller.query) {
                do {
                    try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation()
                    await controller.refreshReview(); await controller.resumeApprovedApply()
                } catch { }
            }
            .refreshable { await controller.refresh(); if controller.status?.connected == true { await incoming.refresh() } }
            .task(id: "\(controller.status?.connected == true):\(controller.sync?.run?.state ?? "")") { if controller.status?.connected == true { await incoming.refresh() } }
            .task(id: controller.cooldownUntil) {
                clock = .now
                while controller.cooldownUntil > clock && !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    clock = .now
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active && !controller.busy { Task { await controller.refresh() } } }
            .sheet(isPresented: $showSignIn) {
                if let credential = store.browserCredential() {
                    NavigationStack {
                        TraktSignIn(credential: credential) { result in
                            showSignIn = false
                            switch result { case .success: store.invalidateDiscovery(); Task { await controller.refresh() }; case .failure(let error): controller.error = error.localizedDescription }
                        }.navigationTitle("Connect Trakt").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSignIn = false } } }
                    }
                }
            }
    }
    private var restoringImport: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Restoring approved import").font(.headline)
            Text(controller.retryMessage ?? "Checking your Trakt connection and saved review before continuing.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if coolingDown {
                Text("Checking again after \(controller.cooldownUntil.formatted(date: .abbreviated, time: .standard)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Pause import", systemImage: "pause.fill") { controller.pauseApplying() }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(controller.paused)
                .accessibilityIdentifier("trakt-pause-restoration")
        }.diaryPanel().accessibilityElement(children: .contain).accessibilityIdentifier("trakt-restoring-import")
    }
    private func transferProgress(_ sync: TraktSync) -> some View {
        let progress = TraktApplyProgress(sync)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.applyingAll ? "Importing reviewed changes" : "Import progress").font(.headline)
                Spacer(minLength: 8)
                Text("\(progress.percent)%").font(.headline).monospacedDigit().foregroundStyle(theme.accent)
                    .accessibilityIdentifier("trakt-apply-percent")
            }
            ProgressView(value: progress.fraction).accessibilityLabel("Reviewed sync progress")
                .accessibilityValue("\(progress.finished) of \(progress.total) processed")
                .accessibilityIdentifier("trakt-apply-progress")
            Text("\(progress.applied.formatted()) saved · \(progress.skipped.formatted()) skipped · \(progress.remaining.formatted()) remaining")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("trakt-apply-counts")
            if progress.failed > 0 { Text("\(progress.failed.formatted()) changes need attention; they are kept for review.").font(.caption).foregroundStyle(.orange) }
            if let message = controller.retryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if controller.applyingAll {
                if coolingDown {
                    Text("Resuming automatically after \(controller.cooldownUntil.formatted(date: .omitted, time: .standard)).")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("trakt-auto-resume")
                } else { Text("You can browse the other tabs while this continues. Keep the app open.").font(.caption).foregroundStyle(.secondary) }
                Button(controller.paused ? "Pausing after this request…" : "Pause import", systemImage: "pause.fill") { controller.pauseApplying() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(controller.paused).accessibilityIdentifier("trakt-pause-import")
            } else if controller.paused && sync.reviewing && (sync.counts["safe"] ?? 0) > 0 {
                Button("Resume import", systemImage: "play.fill") { controller.startApprovedApply() }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).accessibilityIdentifier("trakt-resume-import")
            }
        }.diaryPanel().accessibilityElement(children: .contain).accessibilityIdentifier("trakt-transfer-panel")
    }
    private var incomingWatches: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Incoming watches", isOn: Binding(get: { incoming.status?.enabled ?? false }, set: { enabled in
                Task { await incoming.configure(enabled: enabled) }
            })).disabled(incoming.busy || incoming.status == nil || controller.status?.needsReconnect == true).accessibilityIdentifier("trakt-incoming-toggle")
            Text("Import completed plays from Trakt automatically. Ratings, watchlist changes and deletions still use review.")
                .font(.caption).foregroundStyle(.secondary)
            if incoming.status?.enabled == true {
                Text("Usually within a few minutes. New titles may need extra metadata checks. Your diary refreshes when you open the app.")
                    .font(.caption).foregroundStyle(.secondary)
                if let explanation = incoming.pauseExplanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let date = DiaryDate.parse(incoming.status?.checkedAt) {
                    Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                } else { Text("Waiting for the first scheduled check.").font(.caption).foregroundStyle(.secondary) }
                if let status = incoming.status, status.pending > 0 || status.review > 0 {
                    Text("\(status.pending) waiting · \(status.review) need manual review").font(.caption).foregroundStyle(.secondary)
                }
                if let health = incoming.health { Text(health).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = incoming.error { Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("trakt-incoming-error") }
            Button("Refresh status", systemImage: "arrow.clockwise") { Task { await incoming.refresh() } }
                .font(.subheadline).buttonStyle(.bordered).disabled(incoming.busy).accessibilityIdentifier("trakt-incoming-refresh")
        }.diaryPanel().accessibilityElement(children: .contain).accessibilityIdentifier("trakt-incoming-panel")
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DiaryIcon(name: "link-2", size: 22).foregroundStyle(theme.accent).padding(12).background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) { Text(controller.status?.needsReconnect == true ? "Reconnect Trakt" : controller.status?.connected == true ? "Connected" : controller.loading ? "Checking connection…" : "Connect to Trakt").font(.title3.bold()); Text(controller.status?.username.map { "@" + $0 } ?? "Your watches, together").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if controller.status?.needsReconnect == true { Text("Reconnect").font(.caption.bold()).foregroundStyle(.yellow) }
                else if (controller.sync?.pendingChanges ?? 0) > 0 { Text("Review").font(.caption.bold()).foregroundStyle(.yellow) }
            }
            if let date = DiaryDate.parse(controller.status?.lastSyncAt) { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            if controller.status?.connected == true {
                HStack { Button("Scan Trakt", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") { Task { await controller.scan(start: true) } }.buttonStyle(.borderedProminent).disabled(coolingDown); Button("Disconnect", role: .destructive) { Task { await controller.disconnect() } }.buttonStyle(.bordered) }.disabled(controller.busy)
            } else if controller.status?.configured == true {
                Button("Connect Trakt") { showSignIn = true }.buttonStyle(.borderedProminent).disabled(controller.busy)
                Link("Connect in browser", destination: AppConfiguration.backend.appendingPathComponent("preview/more/trakt")).font(.caption)
            } else if controller.status != nil { Text("Configure the Trakt Client ID on your server using the PC app. Sign-in uses PKCE; no client secret is needed.").font(.subheadline).foregroundStyle(.secondary) }
            if coolingDown {
                Text("Waiting \(max(0, Int(ceil(controller.cooldownUntil.timeIntervalSince(clock))))) seconds before the next request.")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).accessibilityIdentifier("trakt-cooldown-countdown")
            }
        }.diaryPanel()
    }
    private var preferences: some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sync preferences").font(.subheadline.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Decimal ratings", selection: $controller.mode) { ForEach(TraktRatingMode.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu).disabled(controller.busy)
                Text("For the next scan; decimals stay in TwilDiary").font(.caption).foregroundStyle(.secondary)
                Divider(); Text("Included in each scan").font(.caption).foregroundStyle(.secondary)
                Text("Watch history · Ratings · Watchlist").font(.subheadline)
            }.diaryPanel()
        }
    }
    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let run = controller.sync?.run {
                let progress = TraktScanProgress(run: run)
                Text(progress.title).font(.subheadline.weight(.semibold))
                Text(progress.detail).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("trakt-scan-progress-detail")
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).accessibilityLabel("Comparison progress")
                    Text("\(Int((fraction * 100).rounded(.down)))% of this comparison stage").font(.caption).monospacedDigit()
                } else { Text("This stage has no reliable total yet.").font(.caption).foregroundStyle(.secondary) }
            }
            if let message = controller.retryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Manual full-library comparison. Nothing is applied until the review is ready. Automatic incoming watches pause during this scan and review.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.busy { Button(controller.paused ? "Pausing…" : "Pause after this step") { controller.paused = true }.disabled(controller.paused) }
            else {
                HStack {
                    Button("Continue scan") { Task { await controller.scan(start: false) } }.buttonStyle(.borderedProminent).disabled(coolingDown)
                    Button("Stop without applying") { Task { await controller.cancel() } }.buttonStyle(.bordered).accessibilityIdentifier("trakt-stop-manual-scan")
                }
                Text("Stopping keeps your existing diary unchanged and lets automatic incoming watches resume.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.diaryPanel()
    }
    private func review(_ sync: TraktSync) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(sync.run?.state == "building" ? "Preparing review" : "Review changes").font(.title2.bold())
                Spacer()
                if sync.run?.state != "building" { CollectionLayoutToggle(grid: $grid, collection: "trakt-review") }
                Text(sync.run?.state == "building" ? "\(sync.discoveredChanges.formatted()) found so far" : "\(sync.pendingChanges) remaining").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(sync.run?.progress ?? 0) Trakt items scanned. Nothing is saved until you apply it.").font(.subheadline).foregroundStyle(.secondary)
            if let error = sync.run?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if sync.run?.state == "building" {
                Text("Apply, Skip and conflict choices become available after the comparison finishes. Pause and stop above if you only want automatic incoming watches.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trakt-review-preparing")
            }
            else if sync.run?.state == "complete" { Label((sync.counts["skipped"] ?? 0) > 0 ? "Finished with skipped items" : "You’re up to date", systemImage: "checkmark.circle").diaryPanel() }
            else if sync.run?.state == "cancelled" { Text("Scan stopped. Scan again when you’re ready to continue.").font(.subheadline).diaryPanel() }
            else {
                SearchField(placeholder: "Find a title in this review…", text: $controller.query, label: "Search Trakt changes")
                Picker("Filter Trakt changes", selection: $controller.kind) { ForEach(TraktKind.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("trakt-kind")
                CollectionLayout(grid: grid, spacing: 10) { ForEach(Array(controller.visibleItems.prefix(controller.limit))) { change in reviewItem(change, sync: sync) } }
                if controller.visibleItems.isEmpty { Text("No matching changes in this review.").font(.subheadline).foregroundStyle(.secondary) }
                HStack { Text("Showing \(min(controller.limit, controller.visibleItems.count)) of \(controller.visibleItems.count) loaded changes").font(.caption).foregroundStyle(.secondary); Spacer(); if controller.limit < controller.visibleItems.count || sync.next != nil { Button("Load more") { Task { await controller.loadMore() } }.font(.subheadline).disabled(controller.busy) } }
                if sync.reviewing && (sync.counts["safe"] ?? 0) > 0 { applyPanel(sync).padding(.top, 10) }
                if sync.reviewing || sync.run?.state == "building" { Button("Stop this scan") { Task { await controller.cancel() } }.font(.subheadline).disabled(controller.busy) }
            }
        }
    }
    private func applyPanel(_ sync: TraktSync) -> some View {
        VStack(spacing: 9) {
            Button { controller.startApprovedApply() } label: {
                Text(sync.readyChanges > 0 ? "Apply all ready changes (\(sync.readyChanges))" : "Link existing items (\(sync.counts["links"] ?? 0))")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 50)
                    .foregroundStyle(theme.ink).background(theme.accent, in: Capsule())
            }.buttonStyle(.plain).disabled(controller.busy || coolingDown).accessibilityIdentifier("trakt-apply-ready")
            Text("Conflicts need your choice above. Filters only change what’s shown.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
    private func reviewItem(_ change: TraktChange, sync: TraktSync) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(change.kindLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 4).background(theme.accent.opacity(0.1), in: Capsule())
            Text(change.name).font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(change.error ?? change.detail).font(.caption).foregroundStyle(.secondary)
            if let context = change.context {
                if let season = context.season, let episode = context.episode, change.kind == "history" { Text("S\(season) · E\(episode)").font(.caption).foregroundStyle(.secondary) }
                if change.review { Text("TwilDiary: \(reviewValue(change.kind, context.local)) · Trakt: \(reviewValue(change.kind, context.remote))").font(.caption).foregroundStyle(.secondary) }
                else if change.kind == "history" { Text(reviewValue(change.kind, change.direction == "push" ? context.local : context.remote)).font(.caption).foregroundStyle(.secondary) }
            }
            if ["applied", "skipped"].contains(change.state) { Text(change.state.capitalized).font(.caption).foregroundStyle(.secondary) }
            else {
                // A single subtree keeps each review action unique in accessibility.
                // ViewThatFits retained two sets of buttons, including hidden candidates.
                let layout = grid || dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 8))
                layout { changeActions(change) }.disabled(controller.busy || !sync.reviewing)
            }
        }.diaryPanel().accessibilityElement(children: .contain).accessibilityIdentifier("trakt-change-" + change.id)
    }
    @ViewBuilder private func changeActions(_ change: TraktChange) -> some View {
        if change.state == "uncertain" { action("Check Trakt", change: change, choice: .local) }
        else if change.review && !change.blocked { action("Keep TwilDiary", change: change, choice: .local); action("Use Trakt", change: change, choice: .trakt) }
        else if !change.blocked { action("Apply", change: change, choice: .apply) }
        Button("Skip") { Task { await controller.apply(change: change, choice: .skip); await store.refresh() } }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular).font(.caption)
            .frame(minHeight: 44).frame(maxWidth: grid ? .infinity : nil).accessibilityIdentifier("trakt-skip-" + change.id)
    }
    private func action(_ label: String, change: TraktChange, choice: TraktChoice) -> some View {
        Button(label) { Task { await controller.apply(change: change, choice: choice); await store.refresh() } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.regular).font(.caption)
            .frame(minHeight: 44).frame(maxWidth: grid ? .infinity : nil).disabled(coolingDown).accessibilityIdentifier("trakt-" + choice.rawValue + "-" + change.id)
    }
    private func reviewValue(_ kind: String, _ value: String?) -> String {
        if kind == "rating" { return value ?? "No rating" }
        if kind == "watchlist" { return value == "true" ? "Planned" : "Not planned" }
        return DiaryDate.parse(value).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown date"
    }
    private var coolingDown: Bool { controller.cooldownUntil > clock }
}
