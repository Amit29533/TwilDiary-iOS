import SwiftUI

/// Chrome belongs to its destination. UIKit moves it with that page during a
/// push or interactive pop, including a cancelled pop. No delayed global
/// onAppear flag inserts/removes a safe-area inset after the transition.
private struct DiaryPageChrome: ViewModifier {
    let detail: Bool
    @Environment(DiaryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let label = store.undoLabel {
                UndoToast(label: label).padding(.horizontal, 24).padding(.bottom, 10)
                    // Pops in place (no slide), so Undo is where it looks from the first frame.
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }.animation(Motion.spring(reduceMotion), value: store.undoLabel)
    }
}
extension View {
    func diaryPageChrome(detail: Bool) -> some View { modifier(DiaryPageChrome(detail: detail)) }
}
