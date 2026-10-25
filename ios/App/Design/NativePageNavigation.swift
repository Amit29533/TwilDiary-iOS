import SwiftUI

/// Pushed pages use the system Back button/content-pop gesture. Done remains
/// reserved for modal editing/confirmation, where it has an actual purpose.
private struct NativePageNavigation: ViewModifier {
    let title: String
    let searchIdentifier: String
    let search: () -> Void
    func body(content: Content) -> some View {
        content.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(action: search) { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search").accessibilityIdentifier(searchIdentifier) } }
    }
}
extension View {
    func diaryPageNavigation(_ title: String, searchIdentifier: String, search: @escaping () -> Void) -> some View {
        modifier(NativePageNavigation(title: title, searchIdentifier: searchIdentifier, search: search))
    }
}
