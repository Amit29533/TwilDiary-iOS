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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nativeOnArtwork) private var onArtwork
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Glass needs something behind it: on a plain white page it would vanish, so there the card is
        // the quiet raised grey Apple Music uses; on black and on artwork-tinted pages it is glass.
        if reduceTransparency || (colorScheme == .light && !onArtwork) {
            content.background(Color(uiColor: .secondarySystemBackground), in: shape)
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
    @Environment(\.nativeOnArtwork) private var onArtwork
    @ViewBuilder func body(content: Content) -> some View {
        let accent = Color(uiColor: .systemBlue)
        if onArtwork {
            // On an artwork-tinted page, as Apple Music's Play: a solid white capsule with black text,
            // and the other actions clear glass with white text.
            if prominent {
                content.foregroundStyle(ink ?? .black).background(.white, in: Capsule()).contentShape(Capsule())
            } else {
                content.foregroundStyle(ink ?? .white).glassEffect(.regular.interactive(), in: Capsule()).contentShape(Capsule())
            }
        } else {
            onPage(content, accent: accent)
        }
    }
    private func onPage(_ content: Content, accent: Color) -> some View {
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

private struct NativeOnArtworkKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}
extension EnvironmentValues {
    /// Native: this page is tinted by its artwork (a title's page), so it is dark with white text,
    /// its cards are glass and its main action is a white capsule.
    var nativeOnArtwork: Bool {
        get { self[NativeOnArtworkKey.self] }
        set { self[NativeOnArtworkKey.self] = newValue }
    }
}

extension View {
    /// A title's page in Native: tinted by its artwork, dark with white text (in light mode too), as
    /// Apple Music's album and playlist pages. Nothing changes in the other themes (already dark).
    func nativeArtworkPage() -> some View { modifier(NativeArtworkPage()) }
}

private struct NativeArtworkPage: ViewModifier {
    func body(content: Content) -> some View {
        if ThemeStore.current.native {
            content.environment(\.colorScheme, .dark).environment(\.nativeOnArtwork, true)
        } else {
            content
        }
    }
}

/// One choice of a `NativeSegmentedControl`.
struct NativeSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    /// The accessibility identifier (UI tests find segments by it).
    let id: String
}

/// iOS 26's segmented control on Liquid Glass: the choices share one glass track and the chosen one
/// sits on a raised thumb that springs across, with a light tap.
struct NativeSegmentedControl<Value: Hashable>: View {
    let segments: [NativeSegment<Value>]
    @Binding var selection: Value
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                let on = segment.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.22)) { selection = segment.value }
                } label: {
                    Text(segment.title).font(.system(size: 14, weight: on ? .semibold : .medium)).foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1).minimumScaleFactor(0.85).padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if on {
                                Capsule().fill(ThemePalette.adaptive(dark: 0.4, light: 1)).shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier(segment.id)
            }
        }.padding(3).glassEffect(.regular, in: Capsule())
            .sensoryFeedback(.selection, trigger: selection)
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
