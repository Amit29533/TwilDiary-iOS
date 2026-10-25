import SwiftUI
import TwilDiaryCore

enum ContinueCarouselPolicy {
    static func destination(ids: [String], current: String?, forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return forward ? ids[(index + 1) % ids.count] : ids[index == 0 ? ids.count - 1 : index - 1]
    }
    static func cooldownEnded(at date: Date, lastInteraction: Date) -> Bool {
        let elapsed = date.timeIntervalSince(lastInteraction)
        return elapsed.isFinite && elapsed >= 5
    }
}

/// Keeps the existing card geometry; only the small native controls popover is new.
/// No timer runs offscreen, behind another tab/page, during a write or with VoiceOver.
struct ContinueWatchingCarousel: View {
    let titles: [MediaTitle]
    var automaticAllowed = true
    @Environment(DiaryStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @SceneStorage("home.continue.title") private var selection = ""
    @SceneStorage("home.continue.paused") private var paused = false
    @State private var automaticSelection: String?
    @State private var visible = false
    @State private var scrollIdle = true
    @State private var showControls = false
    @State private var initialized = false
    @State private var lastInteraction = Date.distantPast
    private struct RotationKey: Equatable { let enabled: Bool; let ids: [String]; let session: UUID }
    private var ids: [String] { titles.map(\.id) }
    private var position: Binding<String?> {
        Binding(get: { selection.isEmpty ? nil : selection }, set: { if let value = $0 { selection = value } })
    }
    private var automatic: Bool {
        automaticAllowed && visible && scenePhase == .active && router.selectedTab == .home
            && (router.paths[.home]?.count ?? 0) == 0 && router.randomPick == nil
            && !paused && !reduceMotion && !voiceOver && !showControls && scrollIdle
            && !store.busy && store.cardActions.isEmpty && !store.needsSignIn && titles.count > 1
    }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            track.zIndex(0)
            if titles.count > 1 {
                Button { showControls = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background { DiaryControlSurface(shape: Circle()) }
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(2).zIndex(1)
                    .accessibilityLabel("Continue watching controls").accessibilityIdentifier("continue-controls")
            }
        }
            .accessibilityElement(children: .contain).accessibilityIdentifier("continue-carousel")
            .accessibilityLabel("Continue watching")
            .accessibilityValue(titles.first { $0.id == selection }?.name ?? "")
            .popover(isPresented: $showControls) { controls.presentationCompactAdaptation(.popover) }
            .onScrollVisibilityChange(threshold: 0.5) { visible = $0 }
            .onAppear {
                if !initialized {
                    initialized = true
                    #if DEBUG
                    if store.isPreview {
                        selection = ids.first ?? ""
                        paused = !ProcessInfo.processInfo.arguments.contains("--ui-automatic-carousel")
                    }
                    #endif
                }
                reconcile()
            }
            .onChange(of: ids) { _, _ in reconcile() }
            .onChange(of: selection) { _, value in
                if value != automaticSelection { lastInteraction = .now }
                automaticSelection = nil
            }
            .onChange(of: showControls) { _, _ in lastInteraction = .now }
            .onChange(of: store.sessionRevision) { _, _ in
                paused = false; selection = ids.first ?? ""
            }
            .task(id: RotationKey(enabled: automatic, ids: ids, session: store.sessionRevision)) {
                guard automatic else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard automatic, !Task.isCancelled else { return }
                    if ContinueCarouselPolicy.cooldownEnded(at: .now, lastInteraction: lastInteraction) { move(forward: true, automatically: true) }
                }
            }
    }
    private var track: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(titles) { title in
                    ProgressCard(title: title, compact: true)
                        .containerRelativeFrame(.horizontal, count: 1, spacing: 12).id(title.id)
                }
            }.scrollTargetLayout()
        }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            .scrollPosition(id: position, anchor: .leading)
            .onScrollPhaseChange { _, phase in
                scrollIdle = phase == .idle
                if phase == .tracking || phase == .interacting { lastInteraction = .now }
            }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue watching").font(.headline)
            Button("Previous title", systemImage: "chevron.left") { move(forward: false); showControls = false }
                .accessibilityIdentifier("continue-previous")
            Button("Next title", systemImage: "chevron.right") { move(forward: true); showControls = false }
                .accessibilityIdentifier("continue-next")
            Button(paused ? "Start automatic carousel" : "Pause automatic carousel", systemImage: paused ? "play" : "pause") {
                paused.toggle(); showControls = false
            }.disabled(reduceMotion || voiceOver).accessibilityIdentifier("continue-pause")
            if reduceMotion || voiceOver { Text("Automatic rotation is off while Reduce Motion or VoiceOver is on.").font(.caption).foregroundStyle(.secondary) }
        }.buttonStyle(.bordered).buttonBorderShape(.capsule).padding(16).frame(width: 250)
    }
    private func reconcile() {
        if ids.contains(selection) { return }
        selection = ids.first ?? ""
    }
    private func move(forward: Bool, automatically: Bool = false) {
        guard let next = ContinueCarouselPolicy.destination(ids: ids, current: selection, forward: forward) else { return }
        if automatically { automaticSelection = next } else { lastInteraction = .now }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { selection = next }
    }
}
