import Foundation

/// Mirrors domain/random-pick.ts, including its sample bounds. (The logo's triple tap is now a long
/// press; a tap opens JellySpace.)
public enum RandomPick {
    public static func choose(_ titles: [MediaTitle], previousID: String? = nil, sample: Double = Double.random(in: 0..<1)) -> MediaTitle? {
        let active = titles.filter { $0.deletedAt == nil }
        let candidates = active.count > 1 ? active.filter { $0.id != previousID } : active
        guard !candidates.isEmpty else { return nil }
        let fraction = sample.isFinite ? min(1, max(0, sample)) : 0
        let index = min(candidates.count - 1, Int((fraction * Double(candidates.count)).rounded(.down)))
        return candidates[index]
    }

}
