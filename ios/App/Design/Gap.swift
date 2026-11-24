import SwiftUI

/// The app's spacing: one set of gaps for every page (owner's request: the space between rows and
/// columns the same everywhere). Pages lay out sections, headings, shelves and grids with these
/// rather than numbers of their own.
enum Gap {
    /// Between a page's sections (a shelf, a card with its heading, a group of rows).
    static let section: CGFloat = 28
    /// A section heading row's height: the round see-all button's tap size. Every heading row is
    /// at least this tall, with or without the button, so headings sit the same distance from what
    /// they head.
    static let headingRow: CGFloat = 44
    /// From a section's heading row to its content.
    static let heading: CGFloat = 8
    /// Between cards in a sideways shelf, and between the columns of a grid.
    static let item: CGFloat = 12
    /// Between the rows of a grid of posters or cards with captions under them.
    static let gridRow: CGFloat = 18
    /// Between the rows of a grid of tiles (no caption under them).
    static let tileRow: CGFloat = 12
    /// A page's side margin.
    static let gutter: CGFloat = 14
    /// A poster's corner (every 2:3 poster card, at any size), before Design Lab's Corners choice.
    static let posterCorner: CGFloat = 12
}

/// The count beside a heading ("Shows 45", "Continue 12", "Episodes 10"): one grey pill everywhere.
struct CountPill: View {
    let count: Int
    var body: some View {
        Text(count.formatted()).font(.app(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary).monospacedDigit()
            .lineLimit(1).fixedSize().padding(.horizontal, 9).frame(height: 24)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}
