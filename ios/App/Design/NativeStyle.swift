import SwiftUI
import UIKit

// Native (owner's request: "it should feel like a new app made by Apple"): the pieces that replace
// the app's own controls when Native is on. Everything here uses the system's colours, so it is
// right in light and dark mode; nothing is drawn in a colour of the app's own.

/// A Settings-style tile: a white symbol on a rounded square of a system colour. The colour comes
/// from what the symbol shows (bells red, clocks blue, sync green…), so the same row always has the
/// same colour, as in the Settings app.
struct NativeTile: View {
    let symbol: String
    var size: CGFloat = 30
    /// A colour chosen by the caller (the Settings rows' own tints); otherwise one for the symbol.
    var color: Color? = nil
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white)
            .symbolRenderingMode(.monochrome)
            .frame(width: size, height: size)
            .background((color ?? Self.color(for: symbol)).gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }

    private static let keyed: [(String, UIColor)] = [
        ("bell", .systemRed), ("calendar", .systemRed), ("heart", .systemPink), ("star", .systemYellow),
        ("trash", .systemGray), ("gear", .systemGray), ("slider", .systemGray), ("wrench", .systemGray), ("hammer", .systemGray),
        ("lock", .systemBlue), ("key", .systemGray), ("hand", .systemBlue), ("shield", .systemBlue),
        ("icloud", .systemBlue), ("cloud", .systemOrange), ("server", .systemIndigo), ("externaldrive", .systemGray), ("internaldrive", .systemGray),
        ("arrow.triangle.2.circlepath", .systemGreen), ("arrow.clockwise", .systemGreen), ("arrow.2.circlepath", .systemGreen), ("arrow.down", .systemBlue), ("arrow.up", .systemBlue),
        ("globe", .systemBlue), ("character", .systemGray), ("textformat", .systemGray), ("person", .systemGray), ("figure", .systemGreen),
        ("film", .systemIndigo), ("tv", .systemIndigo), ("play", .systemIndigo), ("popcorn", .systemOrange), ("ticket", .systemOrange),
        ("sparkle", .systemPurple), ("wand", .systemPurple), ("chart", .systemOrange), ("clock", .systemBlue), ("timer", .systemOrange), ("hourglass", .systemOrange),
        ("doc", .systemBlue), ("folder", .systemBlue), ("tray", .systemBlue), ("archivebox", .systemBrown), ("square.and.arrow", .systemBlue),
        ("link", .systemGray), ("wifi", .systemBlue), ("antenna", .systemGreen), ("network", .systemBlue), ("moon", .systemIndigo), ("sun", .systemBlue),
        ("bolt", .systemOrange), ("eye", .systemTeal), ("info", .systemGray), ("questionmark", .systemBlue), ("paintpalette", .systemPink), ("paintbrush", .systemBlue),
        ("photo", .systemTeal), ("camera", .systemGray), ("magnifyingglass", .systemGray), ("list", .systemOrange), ("checkmark", .systemGreen), ("xmark", .systemRed),
        ("bookmark", .systemOrange), ("books", .systemBrown), ("book", .systemOrange), ("rectangle.portrait", .systemOrange), ("circle.dotted", .systemTeal),
    ]
    private static let fallback: [UIColor] = [.systemBlue, .systemIndigo, .systemOrange, .systemTeal, .systemGreen, .systemPink, .systemPurple]
    static func color(for symbol: String) -> Color {
        if let hit = keyed.first(where: { symbol.hasPrefix($0.0) || symbol.contains("." + $0.0) }) { return Color(uiColor: hit.1) }
        let sum = symbol.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(uiColor: fallback[sum % fallback.count])
    }
}

extension View {
    /// A Liquid Glass capsule: the accent glass with white text (`prominent`, as `.glassProminent`),
    /// or clear glass with accent text, as iOS 26's own buttons.
    func nativeGlassCapsule(prominent: Bool, ink: Color? = nil) -> some View {
        modifier(NativeGlassCapsule(prominent: prominent, ink: ink))
    }
    /// Native's card: Liquid Glass with continuous corners and no outline (owner's request: more
    /// glass), over the page's soft artwork glow; a plain raised fill under Reduce Transparency.
    func nativeCard(radius: CGFloat = 26) -> some View {
        modifier(NativeGlassCard(radius: radius))
    }
    /// A card's surface: the theme's card colour, or Liquid Glass in Native.
    func cardSurface(_ radius: CGFloat) -> some View {
        modifier(CardSurface(radius: radius))
    }
    /// A light tap under the finger in Native when `trigger` changes (a choice made), as system pickers give.
    func nativeSelectionFeedback<T: Equatable>(_ trigger: T) -> some View {
        sensoryFeedback(.selection, trigger: trigger) { _, _ in ThemeStore.current.native }
    }
}

private struct NativeGlassCard: ViewModifier {
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

private struct CardSurface: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if ThemeStore.current.native {
            content.nativeCard(radius: radius)
        } else {
            content.background(HomeStyle.card, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct NativeGlassCapsule: ViewModifier {
    let prominent: Bool
    let ink: Color?
    func body(content: Content) -> some View {
        let accent = Color(uiColor: .systemBlue)
        content.foregroundStyle(ink ?? (prominent ? .white : accent))
            .glassEffect(prominent ? .regular.tint(accent).interactive() : .regular.interactive(), in: Capsule())
            .contentShape(Capsule())
    }
}

extension View {
    /// Native: an artwork header keeps its dark look (white text on the picture, in light mode too)
    /// and ends in rounded corners on the page, as a featured header in Apple's apps. Other themes
    /// are dark already, so nothing changes there.
    func nativeHero(radius: CGFloat = 34) -> some View { modifier(NativeHero(radius: radius)) }
}

private struct NativeHero: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if ThemeStore.current.native {
            content.environment(\.colorScheme, .dark).clipShape(HeroClip(radius: radius))
        } else {
            content
        }
    }
}

/// The header's shape: open at the top (artwork reaching up under the status bar or stretched by a
/// pull stays whole), rounded at the bottom.
private struct HeroClip: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let tall = CGRect(x: rect.minX, y: rect.minY - 4000, width: rect.width, height: rect.height + 4000)
        return UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous).path(in: tall)
    }
}

/// A slowly moving mesh of system indigo, purple, blue and teal behind a summary card (Stats),
/// as the colour fields of Apple's newer apps. Still under Reduce Motion; 20 frames a second at most.
struct NativeMeshGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let colours: [Color] = [UIColor.systemIndigo, .systemPurple, .systemBlue, .systemBlue, .systemIndigo, .systemTeal, .systemPurple, .systemBlue, .systemIndigo]
        .map { Color(uiColor: $0) }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let x = Float(sin(time * 0.45)) * 0.14, y = Float(cos(time * 0.35)) * 0.14
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5 + x, 0.5 + y], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: Self.colours)
        }
    }
}

/// A round Liquid Glass button face (see all, layout, more): the glass circle iOS 26 uses for a
/// bar's icon buttons, with the symbol in the primary label colour.
struct NativeRoundGlass: View {
    var system = "chevron.right"
    var selected = false
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: system).font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(selected ? Color.white : Color(uiColor: .label))
            .frame(width: size, height: size)
            .glassEffect(selected ? .regular.tint(Color(uiColor: .systemBlue)).interactive() : .regular.interactive(), in: Circle())
            .frame(width: 44, height: 44).contentShape(Circle())
    }
}
