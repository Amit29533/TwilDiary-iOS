import Foundation

/// Geometry shared by the phone bar and its drag/cancellation regressions.
public enum NavigationScrub {
    public static func index(x: Double, width: Double, count: Int = 5, inset: Double = 4) -> Int? {
        guard x.isFinite, width.isFinite, inset.isFinite, inset >= 0, width > inset * 2, (1...32).contains(count) else { return nil }
        let clamped = min(width - inset, max(inset, x))
        if clamped == width - inset { return count - 1 }
        let fraction = (clamped - inset) / (width - inset * 2)
        return min(count - 1, max(0, Int(floor(fraction * Double(count)))))
    }
    public static func acceptsRelease(x: Double, y: Double, width: Double, height: Double) -> Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 8 && height > 0 && x >= 0 && x <= width && y >= -24 && y <= height + 24
    }
}
