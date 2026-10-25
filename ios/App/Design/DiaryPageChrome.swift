import SwiftUI

/// Chrome belongs to its destination. UIKit moves it with that page during a
/// push or interactive pop, including a cancelled pop. No delayed global
/// onAppear flag inserts/removes a safe-area inset after the transition.
private struct DiaryPageChrome: ViewModifier {
    let detail: Bool
    @Environment(DiaryStore.self) private var store
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let label = store.undoLabel {
                UndoToast(label: label).padding(.horizontal, 24).padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
extension View {
    func diaryPageChrome(detail: Bool) -> some View { modifier(DiaryPageChrome(detail: detail)) }
}
