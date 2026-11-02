import SwiftUI

/// Pushed pages use the system Back button/content-pop gesture. Done remains
/// reserved for modal editing/confirmation, where it has an actual purpose.
private struct NativePageNavigation: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
extension View {
    func diaryPageNavigation(_ title: String) -> some View {
        modifier(NativePageNavigation(title: title))
    }
}
