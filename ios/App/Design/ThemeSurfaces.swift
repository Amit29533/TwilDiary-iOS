import SwiftUI

/// Shared theme surfaces. Foreground artwork stays sharp; Glass may reveal the
/// separate bounded blurred background underneath the material.
struct DiaryPanelModifier: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = 22
    var accentBorder = false
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
            .overlay(RoundedRectangle(cornerRadius: theme == .glass ? 24 : radius).strokeBorder(theme == .glass ? .white.opacity(28.0 / 255) : accentBorder ? theme.accent.opacity(0.2) : .white.opacity(0.13)))
            .shadow(color: .black.opacity(theme == .glass ? 0.3 : 0), radius: theme == .glass ? 16 : 0, y: theme == .glass ? 12 : 0)
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

/// Phone navigation tokens from tokens.css and the Liquid Glass overrides in themes.css.
struct DiaryNavigationSurface: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency {
                Capsule().fill(Color(webHex: theme == .glass ? "#19191d" : "#111115"))
            } else {
                Capsule().fill(.clear).glassEffect(in: Capsule())
                if theme == .glass {
                    Capsule().fill(Color(webHex: "#242428").opacity(0.2))
                    Capsule().fill(LinearGradient(stops: [
                        .init(color: Color(webHex: "#ffffff14"), location: 0),
                        .init(color: Color(webHex: "#ffffff03"), location: 0.48),
                        .init(color: Color(webHex: "#ffffff09"), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    Capsule().fill(LinearGradient(colors: [Color(webHex: "#111518cf"), Color(webHex: "#080b0ee8")], startPoint: .top, endPoint: .bottom))
                }
            }
            if theme == .glass {
                Capsule().fill(RadialGradient(colors: [Color(webHex: "#ffffff1c"), .clear], center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: 245))
                Capsule().fill(RadialGradient(colors: [Color(webHex: "#b4d4ff0c"), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 160))
            }
            Capsule().strokeBorder(Color(webHex: theme == .glass ? "#ffffff30" : "#ffffff26"))
            Capsule().strokeBorder(LinearGradient(colors: [Color(webHex: theme == .glass ? "#ffffff3b" : "#ffffff20"), .clear, Color(webHex: theme == .glass ? "#ffffff0c" : "#ffffff08")], startPoint: .top, endPoint: .bottom))
        }.clipShape(Capsule()).shadow(color: .black.opacity(theme == .glass ? 0.6 : 0.53), radius: 16, y: 8).allowsHitTesting(false)
    }
}

struct DiaryNavigationSelection: View {
    let selected: Bool
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        if selected {
            ZStack {
                if theme == .glass {
                    Capsule().fill(LinearGradient(colors: [Color(webHex: "#ffffff14"), Color(webHex: "#ffffff09")], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Capsule().fill(RadialGradient(colors: [Color(webHex: "#ffffff2b"), .clear], center: UnitPoint(x: 0.2, y: 0), startRadius: 0, endRadius: 72))
                } else {
                    Capsule().fill(LinearGradient(colors: [theme.accent.opacity(0.19), theme.accent.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                Capsule().strokeBorder(theme == .glass ? Color(webHex: "#ffffff12") : theme.accent.opacity(0.15))
                Capsule().strokeBorder(LinearGradient(colors: [theme == .glass ? Color(webHex: "#ffffff38") : theme.accent.opacity(0.3), .clear], startPoint: .top, endPoint: .center))
            }.allowsHitTesting(false)
        }
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
