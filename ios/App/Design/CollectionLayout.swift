import SwiftUI

/// One consistent, labelled layout switch; preferences are owned by each collection.
struct CollectionLayoutToggle: View {
    @Binding var grid: Bool
    let collection: String
    /// A 36 pt circle for sort rows; the tap target stays 44 pt.
    var small = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            withAnimation(Motion.spring(reduceMotion)) { grid.toggle() }
        } label: {
            RoundTool(icon: grid ? "list" : "layout-grid", size: small ? 36 : 44)
        }.buttonStyle(.springPress)
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
