import SwiftUI

/// Loads the next page when the end of a list scrolls into view: no "Load more" button anywhere.
/// It reports real visibility in the scroll view (not just being built), and `token` changes with
/// every page, so a short page that leaves the end in view asks for the next one too.
struct ScrollLoadTrigger: View {
    /// Changes with each loaded page; the item count works.
    let token: Int
    let loading: Bool
    let action: () -> Void
    var body: some View {
        ZStack { if loading { ProgressView().padding(.vertical, 16) } }
            .frame(maxWidth: .infinity, minHeight: 1)
            .id(token)
            .onScrollVisibilityChange(threshold: 0.01) { visible in if visible && !loading { action() } }
            .accessibilityHidden(!loading)
    }
}
