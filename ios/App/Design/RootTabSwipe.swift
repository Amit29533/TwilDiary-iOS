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
}
