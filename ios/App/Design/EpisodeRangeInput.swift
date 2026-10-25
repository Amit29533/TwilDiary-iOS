import SwiftUI
import UIKit

/// A real native adjustable control with a 44pt touch area and transparent artwork.
/// Explicit track tracking avoids relying on a nearly invisible SwiftUI slider thumb.
@MainActor struct EpisodeRangeInput: UIViewRepresentable {
    let value: Double
    let maximum: Int
    let enabled: Bool
    let label: String
    let valueText: String
    let identifier: String
    let scope: String
    let onChange: @MainActor (Double) -> Void
    let onCommit: @MainActor (Double) -> Void
    let onCancel: @MainActor () -> Void
    func makeUIView(context: Context) -> TrackSlider {
        let control = TrackSlider()
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        let states: [UIControl.State] = [.normal, .highlighted, .disabled]
        for state in states {
            control.setThumbImage(clear, for: state)
            control.setMinimumTrackImage(clear, for: state)
            control.setMaximumTrackImage(clear, for: state)
        }
        control.backgroundColor = .clear; control.minimumValue = 0
        control.isAccessibilityElement = true; control.accessibilityTraits = .adjustable
        updateUIView(control, context: context)
        return control
    }
    func updateUIView(_ control: TrackSlider, context: Context) {
        control.present(value: Float(value), maximum: Float(max(1, maximum)), enabled: enabled, scope: scope)
        control.accessibilityLabel = label; control.accessibilityValue = valueText; control.accessibilityIdentifier = identifier
        control.changed = onChange; control.committed = onCommit; control.cancelled = onCancel
    }
    final class TrackSlider: UISlider {
        private(set) var dragActive = false
        private var presentedScope: String?
        private var cancelNotification: UUID?
        func present(value: Float, maximum: Float, enabled: Bool, scope: String) {
            let reset = presentedScope != scope || maximumValue != maximum || !enabled
            if reset { cancelDrag(deferNotification: true) }
            presentedScope = scope; maximumValue = maximum; isEnabled = enabled
            // A SwiftUI parent update must not move the finger's active draft.
            // A new title/season/range or disabled control cancels that draft.
            if !dragActive { setValue(value, animated: false) }
        }
        private weak var popGesture: UIGestureRecognizer?
        private var popWasEnabled = false
        private func protectTracking() {
            guard popGesture == nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let gesture = controller.navigationController?.interactiveContentPopGestureRecognizer {
                    popGesture = gesture; popWasEnabled = gesture.isEnabled; gesture.isEnabled = false; return
                }
                responder = current.next
            }
        }
        private func restoreNavigation() { popGesture?.isEnabled = popWasEnabled; popGesture = nil }
        override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelDrag(deferNotification: true); restoreNavigation() } }
        var changed: (@MainActor (Double) -> Void)?
        var committed: (@MainActor (Double) -> Void)?
        var cancelled: (@MainActor () -> Void)?
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            beginDrag(at: touch.location(in: self))
        }
        @discardableResult func beginDrag(at point: CGPoint) -> Bool {
            guard isEnabled else { return false }
            cancelNotification = nil; dragActive = true; protectTracking(); updateCount(at: point); return true
        }
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard dragActive, isEnabled else { return false }
            updateCount(at: touch.location(in: self)); return true
        }
        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            guard dragActive, isEnabled else { restoreNavigation(); return }
            if let touch { updateCount(at: touch.location(in: self)) }
            dragActive = false; restoreNavigation(); committed?(Double(value))
        }
        func cancelDrag(deferNotification: Bool = false) {
            guard dragActive else { return }
            dragActive = false; restoreNavigation()
            guard deferNotification else { cancelled?(); return }
            // updateUIView must not synchronously mutate a SwiftUI State value.
            // A fresh finger interaction invalidates this old cancellation.
            let ticket = UUID(), action = cancelled
            cancelNotification = ticket
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.cancelNotification == ticket, !self.dragActive else { return }
                self.cancelNotification = nil; action?()
            }
        }
        override func cancelTracking(with event: UIEvent?) { cancelDrag() }
        override func accessibilityIncrement() { adjust(by: 1) }
        override func accessibilityDecrement() { adjust(by: -1) }
        private func updateCount(at point: CGPoint) {
            guard bounds.width > 0 else { return }
            let fraction = min(1, max(0, point.x / bounds.width))
            value = Float((Double(fraction) * Double(maximumValue)).rounded())
            changed?(Double(value))
        }
        private func adjust(by amount: Float) {
            guard isEnabled else { return }
            value = min(maximumValue, max(minimumValue, value + amount))
            changed?(Double(value)); committed?(Double(value))
        }
    }
}
