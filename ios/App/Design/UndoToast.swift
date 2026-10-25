import SwiftUI
import UIKit

/// A short, readable Undo window. Repeated actions and active recovery restart its lifetime.
struct UndoToast: View {
    let label: String
    @Environment(DiaryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @GestureState private var touching = false
    private struct Lifetime: Equatable {
        let notice: UUID
        let busy: Bool
        let recovering: Bool
        let touching: Bool
    }
    var body: some View {
        HStack(spacing: 5) {
            DiaryIcon(name: "check", size: 15).foregroundStyle(Color(webHex: "#79d8bc"))
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(webHex: "#f5f5f7"))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Spacer(minLength: 4)
            Button("Undo") { Task { await store.undo() } }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                .frame(minWidth: 44, minHeight: 44).disabled(store.writesBlocked).accessibilityIdentifier("undo-action")
            Button { store.dismissUndo() } label: { DiaryIcon(name: "x", size: 14).frame(width: 44, height: 44) }
                .foregroundStyle(Color(webHex: "#c5c0cf")).accessibilityLabel("Dismiss undo")
        }.buttonStyle(.plain).padding(.leading, 10).padding(.trailing, 2).frame(maxWidth: 330)
            .background(.black.opacity(0.3), in: Capsule())
            .glassEffect(in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
            .accessibilityElement(children: .contain).accessibilityIdentifier("undo-toast")
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($touching) { _, active, _ in active = true })
            .task(id: Lifetime(notice: store.undoNoticeID, busy: store.busy, recovering: store.needsMutationRefresh, touching: touching)) {
                guard !store.busy, !store.needsMutationRefresh, !touching else { return }
                let notice = store.undoNoticeID
                do { try await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 8 : 4.5)) } catch { return }
                guard !Task.isCancelled, notice == store.undoNoticeID else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { store.dismissUndo() }
            }
    }
}
