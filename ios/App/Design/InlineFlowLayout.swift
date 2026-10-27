import SwiftUI

/// CSS-style wrapping for intrinsic controls, with one accessibility subtree per control.
/// Frames are cached per proposed width: SwiftUI asks for the size and then for
/// placement of the same width, and rows inside lists are laid out often.
struct InlineFlowLayout: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 2
    struct Cache {
        var width: CGFloat?
        var frames: [CGRect] = []
    }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let frames = cachedFrames(subviews, width: proposal.width ?? .infinity, cache: &cache)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let frames = cachedFrames(subviews, width: bounds.width, cache: &cache)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
    private func cachedFrames(_ subviews: Subviews, width: CGFloat, cache: inout Cache) -> [CGRect] {
        if cache.width == width, cache.frames.count == subviews.count { return cache.frames }
        let value = frames(subviews, width: width)
        cache.width = width; cache.frames = value
        return value
    }
    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return subviews.map { view in
            let intrinsic = view.sizeThatFits(.unspecified)
            // Only re-measure a control that must wrap; one that fits keeps its intrinsic size.
            let size = intrinsic.width <= width ? intrinsic : view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}
