import SwiftUI

/// Cines (Home → Cines): a place the owner has named and will shape next. For now, its page.
struct CinesView: View {
    var body: some View {
        EdgeToEdgeScroll {
            VStack(spacing: 10) {
                DiaryIcon(name: "clapperboard", size: 34).foregroundStyle(HomeStyle.secondary)
                Text("Coming soon").font(.app(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 120).padding(.bottom, 100)
            .accessibilityElement(children: .combine).accessibilityIdentifier("cines-coming-soon")
        }
        .diaryScreenBackground().diaryPageNavigation("Cines")
    }
}
