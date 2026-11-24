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
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let tint = color ?? Self.color(for: symbol)
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        // As iOS 26's Settings: dark icons in dark mode (the symbol in its colour on a dark tile), colour tiles in light.
        Image(systemName: symbol).font(.app(size: size * 0.5, weight: .medium)).foregroundStyle(colorScheme == .dark ? tint : .white)
            .symbolRenderingMode(.monochrome)
            .frame(width: size, height: size)
            .background { if colorScheme == .dark { shape.fill(Color.black.opacity(0.55)) } else { shape.fill(tint.gradient) } }
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
    /// A capsule button as iOS Settings draws one: solid accent with white text (`prominent`), or a
    /// grey fill with accent text. Flat, no glass edge (owner: Settings has no shiny borders).
    func nativeGlassCapsule(prominent: Bool, ink: Color? = nil) -> some View {
        modifier(NativeGlassCapsule(prominent: prominent, ink: ink))
    }
    /// Native's card: the grouped list's raised colour with continuous corners, flat and with no
    /// outline, as iOS Settings (owner: no shiny glass borders on cards).
    func nativeCard(radius: CGFloat = 26) -> some View {
        modifier(NativeGlassCard(radius: radius))
    }
    /// A card's surface: the theme's card colour, or Native's flat card.
    func cardSurface(_ radius: CGFloat) -> some View {
        modifier(CardSurface(radius: radius))
    }
}

private struct NativeGlassCard: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        // Design Lab's Corners: Native's cards squarer or rounder (they draw no outline to match).
        content.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: Studio.corner(radius), style: .continuous))
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
            .background(prominent ? accent : Color(uiColor: .tertiarySystemFill), in: Capsule())
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
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}

/// How far a send has got, read from its progress line ("Sending 3 of 10: …" → 0.25), so every
/// service's send (Trakt, MDBList, WeTrakr) can show a bar without each keeping numbers apart.
enum SendProgress {
    static func fraction(_ text: String?) -> Double? {
        guard let text, let match = text.firstMatch(of: #/(\d[\d,]*) of (\d[\d,]*)/#),
              let done = Double(match.1.replacingOccurrences(of: ",", with: "")),
              let total = Double(match.2.replacingOccurrences(of: ",", with: "")), total > 0 else { return nil }
        return min(1, max(0, (done - 0.5) / total))
    }
}

/// A slim progress bar in the theme's accent for a send under way (every service, every theme).
struct SendProgressBar: View {
    let fraction: Double
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ProgressView(value: fraction).tint(theme.accent)
            .animation(reduceMotion ? nil : .smooth, value: fraction)
            .accessibilityLabel("Sent").accessibilityValue("\(Int((fraction * 100).rounded())) percent")
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
                    Text(segment.title).font(.app(size: 14, weight: on ? .semibold : .medium)).foregroundStyle(Color(uiColor: .label))
                        .lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 5).frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if on {
                                Capsule().fill(ThemePalette.adaptive(dark: 0.4, light: 1)).shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : []).accessibilityIdentifier(segment.id)
            }
        }.padding(3).frame(maxWidth: .infinity).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .haptic(.selection, trigger: selection)
    }
}

/// A round Liquid Glass button face (see all, layout, more): the glass circle iOS 26 uses for a
/// bar's icon buttons, with the symbol in the primary label colour.
struct NativeRoundGlass: View {
    var system = "chevron.right"
    var selected = false
    var size: CGFloat = 36
    var body: some View {
        // Studio: layout buttons stay grey whichever layout is on (blue read as "something to do").
        let lit = selected && !Studio.on(.layoutSwitch)
        Image(systemName: system).font(.app(size: size * 0.4, weight: .semibold))
            .foregroundStyle(lit ? Color.white : Color(uiColor: .label))
            .frame(width: size, height: size)
            .background(lit ? Color(uiColor: .systemBlue) : Color(uiColor: .tertiarySystemFill), in: Circle())
            .frame(width: 44, height: 44).contentShape(Circle())
    }
}
