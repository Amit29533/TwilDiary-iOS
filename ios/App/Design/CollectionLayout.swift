import SwiftUI

/// One consistent, labelled layout switch; preferences are owned by each collection.
struct CollectionLayoutToggle: View {
    @Binding var grid: Bool
    let collection: String
    /// A small rounded square for sort rows; glass adds its own padding around the label.
    var small = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) { grid.toggle() }
        } label: {
            Image(systemName: grid ? "list.bullet" : "square.grid.2x2")
                .font(.system(size: 17, weight: .medium)).contentTransition(.symbolEffect(.replace))
                .frame(width: small ? 28 : 44, height: small ? 22 : 44)
        }.buttonStyle(.glass).buttonBorderShape(small ? .roundedRectangle(radius: 12) : .automatic)
            .accessibilityLabel("Show " + collection + (grid ? " as list" : " as grid"))
            .accessibilityValue(grid ? "Grid" : "List").accessibilityIdentifier(collection + "-layout")
            .sensoryFeedback(.selection, trigger: grid)
    }
}

/// Use the same lazy container in both modes so row identity and loaded metadata survive.
struct CollectionLayout<Content: View>: View {
    let grid: Bool
    var spacing: CGFloat = 12
    let content: Content
    init(grid: Bool, spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.grid = grid; self.spacing = spacing; self.content = content()
    }
    var body: some View {
        LazyVGrid(columns: grid ? [GridItem(.flexible(), spacing: spacing, alignment: .top), GridItem(.flexible(), spacing: spacing, alignment: .top)] : [GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: spacing) { content }
    }
}

/// A Done action belongs to the stack that presented the page, including nested sheets.
struct DiaryBackAction: Sendable {
    let perform: @MainActor @Sendable () -> Bool
}
private struct DiaryBackKey: EnvironmentKey {
    static let defaultValue: DiaryBackAction? = nil
}
extension EnvironmentValues {
    var diaryBack: DiaryBackAction? {
        get { self[DiaryBackKey.self] }
        set { self[DiaryBackKey.self] = newValue }
    }
}
