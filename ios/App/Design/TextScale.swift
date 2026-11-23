import SwiftUI
import Synchronization

/// Text that follows iPhone's Text Size (Settings → Display & Brightness → Text Size). The app's
/// fonts were fixed sizes (about 1,300 of them), so a bigger setting changed almost nothing. Each
/// is now scaled from the size it was written for, which is what the default setting shows (so the
/// app looks exactly as designed there); the largest settings are held back a little, as rows and
/// buttons keep their size. The player and the subtitles keep their own sizes.
enum TextScale {
    private static let factor = Mutex<CGFloat>(1)
    /// The scale now (1 at the default Text Size).
    static var current: CGFloat { factor.withLock { $0 } }
    static func set(_ size: DynamicTypeSize) {
        let value = Self.scale(size)
        factor.withLock { $0 = value }
    }
    static func scale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 0.95
        case .large: 1
        case .xLarge: 1.08
        case .xxLarge: 1.15
        case .xxxLarge: 1.22
        default: size.isAccessibilitySize ? 1.28 : 1
        }
    }
}

extension Font {
    /// The system font at this size for the default Text Size, scaled with yours (see TextScale).
    static func app(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: size * TextScale.current, weight: weight, design: design)
    }
}
