import SwiftUI
import TwilDiaryCore

@MainActor struct TraktView: View {
    let store: DiaryStore
    @State private var controller: TraktController
    @State private var incoming: IncomingTraktController
    @State private var showSignIn = false
    @State private var clock = Date.now
    @State private var groupAction: GroupAction?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @AppStorage("traktGrid") private var grid = false
    @State private var scanPace = ProgressPace()
    @State private var applyPace = ProgressPace()
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
                    // A running scan leads the page; settings follow it.
                    if scanning { scanProgress; foundSoFar }
                    preferences
                    incomingWatches
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
                // One wake-up at the end of the cooldown re-enables the controls. The
                // per-second countdown is a TimelineView, so the whole Trakt screen and
                // its review rows are no longer rebuilt every second.
                clock = .now
                let wait = controller.cooldownUntil.timeIntervalSince(clock)
                guard wait > 0 else { return }
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                clock = .now
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active && !controller.busy { Task { await controller.refresh() } } }
            .onChange(of: paceKey) { _, _ in recordPace() }
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
                .buttonStyle(.diarySecondary).disabled(controller.paused)
                .accessibilityIdentifier("trakt-pause-restoration")
        }.diaryPanel().accessibilityElement(children: .contain).accessibilityIdentifier("trakt-restoring-import")
    }
    private func transferProgress(_ sync: TraktSync) -> some View {
        let progress = TraktApplyProgress(sync)
        let left = controller.applyingAll ? ProgressPace.label(seconds: applyPace.secondsLeft(remaining: progress.remaining)) : nil
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(controller.applyingAll ? "Applying changes" : "Import progress").font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("\(progress.percent)%").font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(theme.accent)
                        .accessibilityIdentifier("trakt-apply-percent")
                }
                ProgressView(value: progress.fraction).tint(theme.accent).accessibilityLabel("Reviewed sync progress")
                    .accessibilityValue("\(progress.finished) of \(progress.total) processed")
                    .accessibilityIdentifier("trakt-apply-progress")
                HStack {
                    Text("\(progress.finished.formatted()) of \(progress.total.formatted())").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let left { Text(left).foregroundStyle(theme.accent) }
                }.font(.system(size: 13)).monospacedDigit()
                InlineFlowLayout(spacing: 6, rowSpacing: 6) {
                    statPill("\(progress.applied.formatted()) saved", tint: .mint)
                    statPill("\(progress.skipped.formatted()) skipped", tint: Color(webHex: "#c5c0cf"))
                    if progress.failed > 0 { statPill("\(progress.failed.formatted()) need you", tint: .orange) }
                }
                // The plain sentence stays for VoiceOver and for checks on what was saved.
                Text("\(progress.applied.formatted()) saved · \(progress.skipped.formatted()) skipped · \(progress.remaining.formatted()) remaining")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trakt-apply-counts")
            }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
            if coolingDown { cooldownCard }
            else if let message = controller.retryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if controller.applyingAll {
                Button { controller.pauseApplying() } label: {
                    Label(controller.paused ? "Pausing…" : "Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.diaryPrimary).disabled(controller.paused).accessibilityIdentifier("trakt-pause-import")
                Text("Keep the app open; other tabs still work.").font(.caption).foregroundStyle(.secondary)
            } else if controller.paused && sync.reviewing && (sync.counts["safe"] ?? 0) > 0 {
                Button { controller.startApprovedApply() } label: {
                    Label("Resume import", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.diaryPrimary).accessibilityIdentifier("trakt-resume-import")
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("trakt-transfer-panel")
    }
    /// "Trakt asked us to slow down", with a ring counting down the seconds.
    private var cooldownCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, controller.cooldownUntil.timeIntervalSince(context.date))
            let total = max(1, Double(controller.sync?.run?.retryAfter ?? 0), left)
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.orange.opacity(0.25), lineWidth: 4)
                    Circle().trim(from: 0, to: left / total).stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(ceil(left)))s").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }.frame(width: 40, height: 40)
                Text("Trakt asked for a pause. Nothing is lost.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(Color(webHex: "#fac775")).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(webHex: "#2b2516"), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine).accessibilityIdentifier("trakt-cooldown-card")
        }
    }
    private func statPill(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 10).frame(height: 26).background(tint.opacity(0.14), in: Capsule())
    }
    private var incomingWatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Automatic").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    tile("arrow.down.circle.fill", color: Color(webHex: "#5E5CE6"))
                    Toggle(isOn: Binding(get: { incoming.status?.enabled ?? false }, set: { enabled in
                        Task { await incoming.configure(enabled: enabled) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Incoming watches").font(.system(size: 15, weight: .semibold))
                            Text(incomingSubtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.tint(theme.accent).disabled(incoming.busy || incoming.status == nil || controller.status?.needsReconnect == true).accessibilityIdentifier("trakt-incoming-toggle")
                }
                Text("New plays arrive on their own; the rest waits for review.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if incoming.status?.enabled == true, let explanation = incoming.pauseExplanation {
                    Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let status = incoming.status, incoming.status?.enabled == true, status.pending > 0 || status.review > 0 {
                    Text("\(status.pending) waiting · \(status.review) need manual review").font(.caption).foregroundStyle(.secondary)
                }
                if let health = incoming.health { Text(health).font(.caption).foregroundStyle(.secondary) }
                if let error = incoming.error { Text(error).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("trakt-incoming-error") }
                Button { Task { await incoming.refresh() } } label: { Label("Refresh status", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                    .font(.subheadline).buttonStyle(.diarySecondary).disabled(incoming.busy).accessibilityIdentifier("trakt-incoming-refresh")
            }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
        }.accessibilityElement(children: .contain).accessibilityIdentifier("trakt-incoming-panel")
    }
    private var incomingSubtitle: String {
        guard incoming.status?.enabled == true else { return "Off" }
        // Incoming watches pause only while a scan builds; an open review leaves them scheduled.
        if controller.sync?.run?.state == "building" { return "Paused during this scan" }
        if let date = DiaryDate.parse(incoming.status?.checkedAt) { return "Last checked " + date.formatted(date: .abbreviated, time: .shortened) }
        return "Waiting for the first scheduled check"
    }
    private func tile(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).frame(width: 34, height: 34).background(color.gradient, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandLogo(service: .trakt, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.status?.needsReconnect == true ? "Reconnect Trakt" : controller.status?.connected == true ? "Trakt" : controller.loading ? "Checking connection…" : "Connect to Trakt").font(.system(size: 20, weight: .bold))
                    if let date = DiaryDate.parse(controller.status?.lastSyncAt) { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    else if controller.status?.connected != true { Text("Your watches, together").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if controller.status?.needsReconnect == true { statPill("Reconnect", tint: .orange) }
                else if let name = controller.status?.username, controller.status?.connected == true { statPill("@" + name, tint: .mint) }
            }
            if (controller.sync?.pendingChanges ?? 0) > 0 && controller.sync?.run?.state != "building" {
                statPill("\(controller.sync?.pendingChanges ?? 0) to review", tint: .orange)
            }
            if controller.status?.connected == true {
                // Hidden while a scan runs; the scan card has its own Continue and Stop.
                if !scanning { HStack(spacing: 10) {
                    Button { Task { await controller.scan(start: true) } } label: {
                        Label("Scan Trakt", systemImage: "arrow.trianglehead.2.clockwise.rotate.90").lineLimit(1).frame(maxWidth: .infinity)
                    }.buttonStyle(.diaryPrimary).disabled(coolingDown)
                    Button(role: .destructive) { Task { await controller.disconnect() } } label: { Text("Disconnect").lineLimit(1).frame(maxWidth: .infinity) }
                        .buttonStyle(.diarySecondary)
                }.disabled(controller.busy) }
            } else if controller.status?.configured == true {
                Button { showSignIn = true } label: { Text("Connect Trakt").frame(maxWidth: .infinity) }.buttonStyle(.diaryPrimary).disabled(controller.busy)
                Link("Connect in browser", destination: AppConfiguration.backend.appendingPathComponent("preview/more/trakt")).font(.caption)
            } else if controller.status != nil { Text("Add a Trakt Client ID on your server first.").font(.subheadline).foregroundStyle(.secondary) }
            if coolingDown && controller.sync?.reviewing != true {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Next request in \(max(0, Int(ceil(controller.cooldownUntil.timeIntervalSince(context.date)))))s")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).accessibilityIdentifier("trakt-cooldown-countdown")
                }
            }
        }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
    }
    private var scanning: Bool { controller.sync?.run?.state == "building" }
    private var preferences: some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sync preferences").font(.subheadline.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Decimal ratings").font(.subheadline)
                    Spacer(minLength: 8)
                    Menu { Picker("Decimal ratings", selection: $controller.mode) { ForEach(TraktRatingMode.allCases) { Text($0.label).tag($0) } } }
                        label: { FilterPill(label: controller.mode.label) }.disabled(controller.busy).accessibilityIdentifier("trakt-rating-mode")
                }
                Text("For the next scan; decimals stay in TwilDiary").font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Conflicts").font(.subheadline)
                    Spacer(minLength: 8)
                    Menu { Picker("Conflicts", selection: $controller.conflictDefault) { ForEach(TraktConflictDefault.allCases) { Text($0.label).tag($0) } } }
                        label: { FilterPill(label: controller.conflictDefault.label, active: controller.conflictDefault != .ask) }.accessibilityIdentifier("trakt-conflict-default")
                }
                Text(controller.conflictDefault == .ask ? "You choose each conflict in the review" : "Scans apply on their own, conflicts included")
                    .font(.caption).foregroundStyle(.secondary)
                Divider(); Text("Included in each scan").font(.caption).foregroundStyle(.secondary)
                Text("Watch history · Ratings · Watchlist").font(.subheadline)
            }.diaryPanel()
        }
    }
    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let run = controller.sync?.run {
                let progress = TraktScanProgress(run: run)
                let stages = scanStages(run)
                let remaining = stages.done.flatMap { done in stages.total.map { $0 - done } }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.1), lineWidth: 6)
                            Circle().trim(from: 0, to: stages.compare ?? 0).stroke(theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                            if let share = stages.compare { Text("\(Int((share * 100).rounded(.down)))%").font(.system(size: 15, weight: .semibold)).monospacedDigit() }
                            else { ProgressView().controlSize(.small) }
                        }.frame(width: 64, height: 64).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(progress.title).font(.system(size: 16, weight: .semibold))
                            Text(progress.detail).font(.system(size: 13)).foregroundStyle(.secondary).accessibilityIdentifier("trakt-scan-progress-detail")
                            if let left = ProgressPace.label(seconds: remaining.flatMap { scanPace.secondsLeft(remaining: $0) }) {
                                Text(left).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.accent)
                            } else if stages.current == .download { Text("Time left appears once comparing starts").font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    }
                    HStack(spacing: 6) {
                        stageBar("Download", share: stages.current == .download ? nil : 1, active: stages.current == .download)
                        stageBar("Compare", share: stages.current == .download ? 0 : stages.compare, active: stages.current == .compare)
                        stageBar("Review", share: stages.current == .review ? 1 : 0, active: stages.current == .review)
                    }
                    HStack(spacing: 14) {
                        if let rate = scanPace.perSecond { Label("\(Int(rate.rounded())) per sec", systemImage: "bolt.fill") }
                        if let started = scanPace.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in Label(ProgressPace.elapsed(context.date.timeIntervalSince(started)) + " so far", systemImage: "clock") }
                        }
                    }.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }.padding(16).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("trakt-scan-card")
            }
            if coolingDown { cooldownCard }
            else if let message = controller.retryMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if controller.busy {
                Button { controller.paused = true } label: { Label(controller.paused ? "Pausing…" : "Pause after this step", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.diarySecondary).disabled(controller.paused)
            } else {
                HStack(spacing: 10) {
                    Button { Task { await controller.scan(start: false) } } label: { Label("Continue scan", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.diaryPrimary).disabled(coolingDown)
                    Button { Task { await controller.cancel() } } label: { Label("Stop", systemImage: "xmark").frame(maxWidth: .infinity) }
                        .buttonStyle(.diarySecondary).accessibilityLabel("Stop without applying").accessibilityIdentifier("trakt-stop-manual-scan")
                }
            }
            Text("Nothing changes until you review.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// What the comparison has turned up so far: ready to apply, to decide, and links.
    private var foundSoFar: some View {
        let counts = controller.sync?.counts ?? [:]
        let decide = (counts["review:conflict"] ?? 0) + (counts["review:pull"] ?? 0) + (counts["review:push"] ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Found so far").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            HStack(spacing: 0) {
                foundFigure(counts["safe"] ?? 0, "ready")
                foundFigure(decide, "to decide", tint: decide > 0 ? Color(webHex: "#fac775") : nil)
                foundFigure(counts["links"] ?? 0, "to link")
            }.padding(.vertical, 14).background(theme.field, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
        }.accessibilityElement(children: .contain).accessibilityIdentifier("trakt-found-so-far")
    }
    private func foundFigure(_ value: Int, _ label: String, tint: Color? = nil) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted()).font(.system(size: 20, weight: .semibold)).monospacedDigit().foregroundStyle(tint ?? Color(webHex: "#f3f0f7"))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private func stageBar(_ name: String, share: Double?, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(.white.opacity(0.1)).frame(height: 6).overlay(alignment: .leading) {
                if let share { GeometryReader { proxy in Capsule().fill(theme.accent).frame(width: proxy.size.width * share) } }
                else { Capsule().fill(theme.accent.opacity(0.45)) }
            }
            HStack(spacing: 3) {
                if share == 1 && !active { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(name)
            }.font(.system(size: 12, weight: active ? .semibold : .regular)).foregroundStyle(active ? theme.accent : .secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func scanStages(_ run: TraktSync.Run) -> TraktScanStages {
        TraktScanStages(run: run, localPlays: store.workspace.activeEvents.count, localTitles: store.workspace.activeTitles.count)
    }
    /// Changes when the scan or the apply moves; each change adds a pace sample.
    private var paceKey: String {
        let run = controller.sync?.run
        return [run?.stage ?? "", String(run?.page ?? 0), String(run?.progress ?? 0), String(controller.sync.map { TraktApplyProgress($0).finished } ?? 0)].joined(separator: ":")
    }
    private func recordPace() {
        guard let sync = controller.sync, let run = sync.run else { return }
        let now = Date.now
        if run.state == "building" {
            let stages = scanStages(run)
            if let done = stages.done { scanPace.record(done, at: now, scope: run.id + run.stage) }
        }
        if controller.applyingAll { applyPace.record(TraktApplyProgress(sync).finished, at: now, scope: run.id) }
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
            Text("\(sync.run?.progress ?? 0) Trakt items scanned · nothing saved yet").font(.subheadline).foregroundStyle(.secondary)
            if let error = sync.run?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if sync.run?.state == "building" {
                Text("Choices unlock when the comparison finishes.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trakt-review-preparing")
            }
            else if sync.run?.state == "complete" { Label((sync.counts["skipped"] ?? 0) > 0 ? "Finished with skipped items" : "You’re up to date", systemImage: "checkmark.circle").diaryPanel() }
            else if sync.run?.state == "cancelled" { Text("Scan stopped. Scan again when you’re ready to continue.").font(.subheadline).diaryPanel() }
            else {
                SearchField(placeholder: "Find a title in this review…", text: $controller.query, label: "Search Trakt changes")
                Picker("Filter Trakt changes", selection: $controller.kind) { ForEach(TraktKind.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented).accessibilityIdentifier("trakt-kind")
                groupPanel(sync)
                CollectionLayout(grid: grid, spacing: 10) { ForEach(Array(controller.visibleItems.prefix(controller.limit))) { change in reviewItem(change, sync: sync) } }
                if controller.visibleItems.isEmpty { Text("No matching changes in this review.").font(.subheadline).foregroundStyle(.secondary) }
                HStack { Text("Showing \(min(controller.limit, controller.visibleItems.count)) of \(controller.visibleItems.count) loaded changes").font(.caption).foregroundStyle(.secondary); Spacer(); if controller.limit < controller.visibleItems.count || sync.next != nil { Button("Load more") { Task { await controller.loadMore() } }.font(.subheadline).disabled(controller.busy) } }
                let conflicts = sync.counts["review:conflict"] ?? 0, removals = (sync.counts["review:pull"] ?? 0) + (sync.counts["review:push"] ?? 0)
                if sync.reviewing && ((sync.counts["safe"] ?? 0) > 0 || (controller.conflictDefault != .ask && conflicts > 0)) { applyPanel(sync).padding(.top, 10) }
                // Automatic apply settles conflicts, but never deletes: removals always wait for a person.
                if sync.reviewing && controller.conflictDefault != .ask && (sync.counts["safe"] ?? 0) == 0 && conflicts == 0 && removals > 0 {
                    Label(removals.counted("removal needs", "removals need") + " your choice. Automatic apply never deletes.", systemImage: "hand.raised")
                        .font(.system(size: 13)).foregroundStyle(Color(webHex: "#fac775")).accessibilityIdentifier("trakt-removals-waiting")
                }
                if sync.reviewing || sync.run?.state == "building" { Button("Stop this scan") { Task { await controller.cancel() } }.font(.subheadline).disabled(controller.busy) }
            }
        }
    }
    private func applyPanel(_ sync: TraktSync) -> some View {
        VStack(spacing: 9) {
            Button { controller.startApprovedApply() } label: {
                Text(controller.conflictDefault != .ask ? "Apply all " + sync.unresolved.counted("change", "changes") : sync.readyChanges > 0 ? "Apply \(sync.readyChanges) ready changes" : "Link existing items (\(sync.counts["links"] ?? 0))")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
                    .foregroundStyle(theme.ink).background(theme.accent, in: Capsule())
            }.buttonStyle(.plain).disabled(controller.busy || coolingDown).accessibilityIdentifier("trakt-apply-ready")
            Text(controller.conflictDefault == .ask ? "Conflicts still need your choice above." : "Conflicts: \(controller.conflictDefault.label)").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
        // Skipping never changes the diary, so it no longer re-downloads it.
        // Review rows can number in the thousands: per-row actions use bordered
        // capsules (no live glass blur in every row); screen-level actions stay glass.
        Button("Skip") { Task { await controller.apply(change: change, choice: .skip) } }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular).font(.caption)
            .frame(minHeight: 44).frame(maxWidth: grid ? .infinity : nil).accessibilityIdentifier("trakt-skip-" + change.id)
    }
    private func action(_ label: String, change: TraktChange, choice: TraktChoice) -> some View {
        Button(label) { Task { await controller.apply(change: change, choice: choice); await store.refresh() } }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.regular).font(.caption)
            .frame(minHeight: 44).frame(maxWidth: grid ? .infinity : nil).disabled(coolingDown).accessibilityIdentifier("trakt-" + choice.rawValue + "-" + change.id)
    }
    /// One choice for a whole review group, confirmed first because it can change many items.
    struct GroupAction: Identifiable, Sendable {
        let direction: String, choice: TraktChoice, count: Int
        var id: String { direction + ":" + choice.rawValue }
    }
    struct ReviewGroup: Identifiable, Sendable {
        let direction: String, title: String
        var id: String { direction }
    }
    private static let reviewGroups = [ReviewGroup(direction: "pull", title: "Removed on Trakt"),
                                       ReviewGroup(direction: "push", title: "Removed in TwilDiary"),
                                       ReviewGroup(direction: "conflict", title: "Changed on both sides")]
    /// Shown once a group has at least two items; a single item is decided in its own row.
    @ViewBuilder private func groupPanel(_ sync: TraktSync) -> some View {
        let present = Self.reviewGroups.filter { (sync.counts["review:" + $0.direction] ?? 0) >= 2 }
        if sync.reviewing && !present.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Decide a whole group").font(.headline)
                ForEach(present) { group in
                    let direction = group.direction, count = sync.counts["review:" + direction] ?? 0
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(group.title) · \(count.formatted())").font(.subheadline.bold())
                        if controller.resolvingGroup == direction {
                            ProgressView().accessibilityLabel("Working through the remaining items")
                        }
                        HStack(spacing: 8) {
                            groupButton("Keep TwilDiary", direction: direction, choice: .local, count: count)
                            groupButton("Use Trakt", direction: direction, choice: .trakt, count: count)
                            groupButton("Skip all", direction: direction, choice: .skip, count: count)
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("trakt-group-" + direction)
                }
            }
            .diaryPanel()
            .confirmationDialog(groupAction.map { groupTitle($0) } ?? "", isPresented: Binding(get: { groupAction != nil }, set: { if !$0 { groupAction = nil } }),
                                titleVisibility: .visible, presenting: groupAction) { action in
                Button(groupTitle(action), role: groupRemoves(action) ? .destructive : nil) {
                    Task { await controller.resolveAll(direction: action.direction, choice: action.choice) }
                }.accessibilityIdentifier("trakt-group-confirm")
                Button("Cancel", role: .cancel) {}
            } message: { action in Text(groupMessage(action)) }
        }
    }
    private func groupButton(_ label: String, direction: String, choice: TraktChoice, count: Int) -> some View {
        Button(label) { groupAction = GroupAction(direction: direction, choice: choice, count: count) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular).font(.caption)
            .frame(minHeight: 44).disabled(controller.busy || (choice != .skip && coolingDown))
            .accessibilityIdentifier("trakt-group-" + direction + "-" + choice.rawValue)
    }
    private func groupTitle(_ action: GroupAction) -> String {
        let items = action.count == 1 ? "1 item" : "\(action.count.formatted()) items"
        switch action.choice {
        case .local: return "Keep TwilDiary for \(items)"
        case .trakt: return "Use Trakt for \(items)"
        default: return "Skip \(items)"
        }
    }
    /// Choices that delete something: Trakt's removal applied to the diary, or the diary's to Trakt.
    private func groupRemoves(_ action: GroupAction) -> Bool {
        (action.direction == "pull" && action.choice == .trakt) || (action.direction == "push" && action.choice == .local)
    }
    private func groupMessage(_ action: GroupAction) -> String {
        switch (action.direction, action.choice) {
        case (_, .skip): return "Nothing changes on either side. They come back in your next scan."
        case ("pull", .trakt): return "Removes these items from your diary to match Trakt."
        case ("pull", .local): return "Sends these items back to Trakt. Trakt accepts about one change a second, so a large group takes a while; you can keep using the app."
        case ("push", .local): return "Removes these items from Trakt to match your diary."
        case ("push", .trakt): return "Restores these items in your diary from Trakt."
        case (_, .local): return "Sends your diary’s version of these items to Trakt."
        default: return "Replaces your diary’s version of these items with Trakt’s."
        }
    }
    private func reviewValue(_ kind: String, _ value: String?) -> String {
        if kind == "rating" { return value ?? "No rating" }
        if kind == "watchlist" { return value == "true" ? "Planned" : "Not planned" }
        return DiaryDate.parse(value).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown date"
    }
    private var coolingDown: Bool { controller.cooldownUntil > clock }
}
