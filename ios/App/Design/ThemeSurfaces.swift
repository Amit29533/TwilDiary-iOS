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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.padding(padding)
            .background {
                if theme == .glass && !reduceTransparency {
                    RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.22)))
                } else {
                    RoundedRectangle(cornerRadius: theme == .glass ? 24 : radius).fill(Color(webHex: "#111115"))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: theme == .glass ? 24 : radius).strokeBorder(!bordered ? .clear : theme == .glass ? .white.opacity(28.0 / 255) : accentBorder ? theme.accent.opacity(0.2) : .white.opacity(0.13)))
            // Glass panels float; the others are flat, with no (invisible, still rendered) shadow at all.
            .modifier(PanelShadow(on: theme == .glass))
    }
}
private struct PanelShadow: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.shadow(color: .black.opacity(0.3), radius: 16, y: 12) } else { content }
    }
}
/// Flat section and card backgrounds (Settings groups, Explore filters, Files
/// rows, community cards). Glass uses the same translucent material as
/// `diaryPanel`, so a screen never mixes frosted and solid panels; every other
/// theme keeps its exact solid fill, stroke and radius.
struct DiarySectionBackground: ViewModifier {
    let radius: CGFloat
    var fill = Color(webHex: "#111115")
    var stroke = Color.white.opacity(0.13)
    /// Selected rows keep their accent emphasis on glass too.
    var emphasized = false
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let glass = theme == .glass && !reduceTransparency
        content
            .background {
                if glass {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(emphasized ? theme.accent.opacity(0.12) : .black.opacity(0.22)))
                } else {
                    shape.fill(fill)
                }
            }
            .overlay(shape.strokeBorder(glass && !emphasized ? .white.opacity(28.0 / 255) : stroke))
    }
}
extension View {
    func diarySectionBackground(radius: CGFloat, fill: Color = Color(webHex: "#111115"),
                                stroke: Color = .white.opacity(0.13), emphasized: Bool = false) -> some View {
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
            if field || reduceTransparency {
                shape.fill(Color(webHex: field ? "#111115" : "#222226"))
                    .overlay(shape.stroke(selected ? theme.accent.opacity(0.45) : .white.opacity(0.13), lineWidth: 1))
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
    var placeholderGlow: Color { self == .twilight ? Color(webHex: "#a27ac535") : accent.opacity(0x35 / 255.0) }
    var initialsBase: Color { self == .twilight ? Color(webHex: "#1c1728") : ink.mix(with: .black, by: 0.15) }
    /// First stop of the title hero's no-backdrop gradient (Twilight: deep violet).
    var heroFallbackLead: Color { self == .twilight ? Color(webHex: "#3c2c48") : accent.mix(with: .black, by: 0.7) }
    /// Random-pick card base under its optional backdrop.
    var pickBase: Color { self == .twilight ? Color(webHex: "#17121f") : ink.mix(with: .black, by: 0.35) }
    var pickVeil: Color { self == .twilight ? Color(webHex: "#15101966") : pickBase.opacity(0.4) }
}
