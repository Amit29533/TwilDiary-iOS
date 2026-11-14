import SwiftUI

/// Shared theme surfaces. Foreground artwork stays sharp; Glass may reveal the
/// separate bounded blurred background underneath the material.
struct DiaryPanelModifier: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = 22
    var accentBorder = false
    /// False: no outline (a panel on a dark page whose edge would read as a stray line).
    var bordered = true
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    func body(content: Content) -> some View {
        if ThemeStore.current.native {
            // Native: a grouped card, continuous corners, no outline.
            content.padding(padding).nativeCard(radius: radius)
        } else {
            classic(content)
        }
    }
    private func classic(_ content: Content) -> some View {
        content.padding(padding)
            .background { RoundedRectangle(cornerRadius: radius).fill(Color(themed: "#111115")) }
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(!bordered ? .clear : accentBorder ? theme.accent.opacity(0.2) : Color.primary.opacity(0.13)))
    }
}
/// Flat section and card backgrounds (Settings groups, Explore filters, Files
/// rows, community cards). Glass uses the same translucent material as
/// `diaryPanel`, so a screen never mixes frosted and solid panels; every other
/// theme keeps its exact solid fill, stroke and radius.
struct DiarySectionBackground: ViewModifier {
    let radius: CGFloat
    var fill = Color(themed: "#111115")
    var stroke = Color.primary.opacity(0.13)
    /// Selected rows keep their accent emphasis on glass too.
    var emphasized = false
    func body(content: Content) -> some View {
        if ThemeStore.current.native && !emphasized {
            content.nativeCard(radius: radius)
        } else {
            let shape = RoundedRectangle(cornerRadius: radius, style: ThemeStore.current.native ? .continuous : .circular)
            content.background { shape.fill(fill) }.overlay(shape.strokeBorder(stroke))
        }
    }
}
extension View {
    func diarySectionBackground(radius: CGFloat, fill: Color = Color(themed: "#111115"),
                                stroke: Color = Color.primary.opacity(0.13), emphasized: Bool = false) -> some View {
        modifier(DiarySectionBackground(radius: radius, fill: fill, stroke: stroke, emphasized: emphasized))
    }
}
struct DiaryControlSurface<SurfaceShape: Shape>: View {
    let shape: SurfaceShape
    var selected = false
    var field = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if (field && !ThemeStore.current.native) || reduceTransparency {
                shape.fill(Color(themed: field ? "#111115" : "#222226"))
                    .overlay(shape.stroke(selected ? theme.accent.opacity(0.45) : Color.primary.opacity(0.13), lineWidth: 1))
            } else {
                shape.fill(.clear).glassEffect(.regular.tint(selected ? theme.accent.opacity(0.16) : .clear).interactive(), in: shape)
            }
        }.allowsHitTesting(false)
    }
}

/// Fallback surfaces shown when a title has no artwork yet. Twilight keeps its
/// original hand-tuned values; other themes derive the same roles from their own
/// accent and ink instead of showing Twilight's violet in every theme.
extension DiaryTheme {
    var placeholderGlow: Color { self == .twilight ? Color(themed: "#a27ac535") : accent.opacity(0x35 / 255.0) }
    var initialsBase: Color { self == .twilight ? Color(themed: "#1c1728") : ink.mix(with: .black, by: 0.15) }
    /// First stop of the title hero's no-backdrop gradient (Twilight: deep violet).
    var heroFallbackLead: Color { self == .twilight ? Color(themed: "#3c2c48") : accent.mix(with: .black, by: 0.7) }
    /// Random-pick card base under its optional backdrop.
    var pickBase: Color { self == .twilight ? Color(themed: "#17121f") : ink.mix(with: .black, by: 0.35) }
    var pickVeil: Color { self == .twilight ? Color(themed: "#15101966") : pickBase.opacity(0.4) }
}
