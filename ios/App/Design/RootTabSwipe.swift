import SwiftUI
import UIKit

/// Left advances through the tab order; a short or vertical drag does
/// nothing. One release changes at most one tab and never wraps at either end.
enum RootTabSwipe {
    static func destination(from tab: AppTab, translation: CGSize, width: CGFloat) -> AppTab? {
        guard width.isFinite, width > 0, translation.width.isFinite, translation.height.isFinite,
              abs(translation.width) >= max(64, width * 0.18),
              abs(translation.width) > abs(translation.height) * 1.5,
              let index = AppTab.allCases.firstIndex(of: tab) else { return nil }
        let next = index + (translation.width < 0 ? 1 : -1)
        guard AppTab.allCases.indices.contains(next) else { return nil }
        return AppTab.allCases[next]
    }
}

extension RootTabSwipe {
    static func shouldFinish(progress: CGFloat, velocity: CGFloat) -> Bool {
        guard progress.isFinite, velocity.isFinite else { return false }
        // A reversal cancels even after the midpoint; a deliberate fast flick
        // may complete a short drag. No wrap or multi-page skip is possible.
        if velocity < -120 { return false }
        return progress >= 0.35 || (progress > 0.05 && velocity > 500)
    }
    /// Rubber-band offset for a swipe past the first or last tab, using the
    /// UIScrollView edge curve. It follows the finger, slows, and stays under a
    /// quarter of the width however far the drag goes.
    /// Only a genuine sideways scroller (a carousel) keeps horizontal drags. A
    /// vertical list whose content is a fraction of a point wider than its frame
    /// must not: UIKit would let its pan claim the swipe before the tab pager.
    static func isHorizontalScroller(contentWidth: CGFloat, boundsWidth: CGFloat,
                                     bouncesHorizontally: Bool, bouncesVertically: Bool) -> Bool {
        !bouncesVertically && (bouncesHorizontally || contentWidth > boundsWidth + 1)
    }
    static func edgeOffset(_ translation: CGFloat, width: CGFloat) -> CGFloat {
        guard translation.isFinite, width.isFinite, width > 0 else { return 0 }
        let limit = width * 0.25
        let distance = abs(translation)
        let offset = (1 - 1 / (distance * 0.55 / limit + 1)) * limit
        return translation < 0 ? -offset : offset
    }
}
