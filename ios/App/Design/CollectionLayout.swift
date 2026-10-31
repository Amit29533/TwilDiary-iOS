import SwiftUI

/// One consistent, labelled layout switch; preferences are owned by each collection.
struct CollectionLayoutToggle: View {
    @Binding var grid: Bool
    let collection: String
    /// A 36 pt circle for sort rows; the tap target stays 44 pt.
    var small = false
    /// Home uses a horizontal card shelf; other collections keep their existing grid label.
    var gridName = "grid"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            // A quick settle without bounce: the whole collection re-lays out, so a spring made it wobble.
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { grid.toggle() }
        } label: {
            RoundTool(icon: grid ? "list" : "layout-grid", size: small ? 36 : 44)
        }.buttonStyle(.springPress)
            .accessibilityLabel("Show " + collection + (grid ? " as list" : " as " + gridName))
            .accessibilityValue(grid ? gridName.capitalized : "List").accessibilityIdentifier(collection + "-layout")
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
