import SwiftUI

/// CSS-style wrapping for intrinsic controls, with one accessibility subtree per control.
struct InlineFlowLayout: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 2
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(subviews, width: bounds.width)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return subviews.map { view in
            let intrinsic = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, intrinsic.width), height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}
