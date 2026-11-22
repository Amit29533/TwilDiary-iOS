import SwiftUI
import UIKit

/// The app's haptics (owner's request, 2026-11-19): Apple's standard feedback (selection ticks,
/// light and soft taps, success, warning and error) on the small moments that mean something,
/// never on plain taps or while scrolling. One switch turns them all off (Settings → Haptics).
enum Haptics {
    static let key = "haptics.enabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    enum Kind { case selection, light, soft, rigid, success, warning, error }

    /// For an action's result (added, moved to Trash, a list made): played straight away.
    @MainActor static func play(_ kind: Kind) {
        guard enabled else { return }
        switch kind {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.75)
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

extension View {
    /// SwiftUI's sensory feedback when `trigger` changes, if haptics are on.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { _, _ in Haptics.enabled }
    }
    /// The same, only when `condition` holds for the old and new values.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T, condition: @escaping (T, T) -> Bool) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { old, new in Haptics.enabled && condition(old, new) }
    }
}
