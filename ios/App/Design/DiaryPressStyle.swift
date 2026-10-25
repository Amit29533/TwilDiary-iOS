import SwiftUI

/// Short spring feedback follows the finger; no delayed highlight or persistent focus glow.
struct DiaryPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.88 : 1)
            .scaleEffect(!reduceMotion && enabled && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
