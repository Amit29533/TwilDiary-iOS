import SwiftUI

/// Pushed pages use the system Back button/content-pop gesture. Done remains
/// reserved for modal editing/confirmation, where it has an actual purpose.
/// The title follows the owner's design: 22 pt bold, left-aligned beside the back button.
private struct NativePageNavigation: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        content.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                // The centred system title is replaced; the name keeps the back menu's label.
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                ToolbarItem(placement: .topBarLeading) {
                    Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        .fixedSize().accessibilityAddTraits(.isHeader)
                }.sharedBackgroundVisibility(.hidden)
            }
    }
}
extension View {
    func diaryPageNavigation(_ title: String) -> some View {
        modifier(NativePageNavigation(title: title))
    }
}
