import Foundation

/// Mirrors domain/random-pick.ts, including its sample bounds and 850ms logo gesture.
public enum RandomPick {
    public static func choose(_ titles: [MediaTitle], previousID: String? = nil, sample: Double = Double.random(in: 0..<1)) -> MediaTitle? {
        let active = titles.filter { $0.deletedAt == nil }
        let candidates = active.count > 1 ? active.filter { $0.id != previousID } : active
        guard !candidates.isEmpty else { return nil }
        let fraction = sample.isFinite ? min(1, max(0, sample)) : 0
        let index = min(candidates.count - 1, Int((fraction * Double(candidates.count)).rounded(.down)))
        return candidates[index]
    }

    public static func tap(previous: [Double], now: Double) -> (triggered: Bool, taps: [Double]) {
        let taps = previous.filter { now >= $0 && now - $0 <= 0.85 } + [now]
        return taps.count >= 3 ? (true, []) : (false, taps)
    }
}
