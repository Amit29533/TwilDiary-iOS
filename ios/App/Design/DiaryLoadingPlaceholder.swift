import SwiftUI
import UIKit

/// The shape of what's loading, so the placeholder sits where the content will land and the page
/// doesn't jump when it arrives (owner's request).
enum PlaceholderLayout {
    /// A block with two lines under it (a card, a chart, a page part).
    case block
    /// Rows of a small poster and two lines (search results, episodes, lists, people).
    case list(rows: Int = 5)
    /// A grid of 2:3 posters with a name and a line under each (Canvas, Explore, filmographies).
    case posterGrid(columns: Int = 3, rows: Int = 2)
    /// One sideways shelf of posters, sized as the real shelf: posters a column wide (as many to a
    /// screen as Posters' size) with the two-line name and details line `CatalogPoster` keeps.
    case posterShelf
    /// The same shelf with `StandardPoster`'s one-line name and subtitle (Explore's seasonal and
    /// coming-soon rows).
    case standardShelf
    /// Home's shelf of fixed-width posters (`HomePoster`).
    case homeShelf
    /// A portrait beside a few lines, then a paragraph (person and character pages).
    case profile
    /// Rows of a name and a count over a thin bar (Statistics' Studios).
    case bars(rows: Int = 5)
    /// A shelf of rounded portraits with a name and a line under each (`MostWatchedShelf`).
    case peopleShelf
    /// Three round photos with a name and a count, then See all (`MostWatchedShelf`'s round row).
    case peopleRound
    /// Cards of one height, one under another (related collections).
    case cards(count: Int = 3, height: CGFloat = 132)
    /// A title's page (`TitleHero`): the cover, the poster beside the name, its year line and chips,
    /// the ratings bar and the synopsis, each where it will land (`coverStrip` as the page passes it).
    case titlePage(coverStrip: CGFloat)
}

/// What shows while something loads: grey shapes laid out like the content that's coming, gently
/// pulsing, as Apple's own apps show loading (no spinner rows that push the page about). The same in
/// every theme. Background refreshes keep the loaded content instead. Still under Reduce Motion.
struct DiaryLoadingPlaceholder: View {
    var height: CGFloat = 160
    var label = "Loading content"
    var layout: PlaceholderLayout = .block
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @PosterSizing private var posterSize
    var body: some View {
        shapes
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.45]) { view, strength in view.opacity(strength) } animation: { _ in .easeInOut(duration: 0.9) }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }

    /// iOS's own fill colours in every theme (the placeholder is part of the app, not a theme): they
    /// follow light and dark by themselves.
    private var fill: Color { Color(uiColor: .tertiarySystemFill) }
    private var line: Color { Color(uiColor: .systemFill) }
    private var faint: Color { Color(uiColor: .tertiarySystemFill) }

    @ViewBuilder private var shapes: some View {
        switch layout {
        case .block: block
        case .list(let rows): list(rows)
        case .posterGrid(let columns, let rows): grid(columns: columns, rows: rows)
        case .posterShelf: shelf(oneLine: false)
        case .standardShelf: shelf(oneLine: true)
        case .homeShelf: homeShelf
        case .profile: profile
        case .bars(let rows): bars(rows)
        case .peopleShelf: peopleShelf
        case .peopleRound: peopleRound
        case .cards(let count, let height): cards(count, height: height)
        case .titlePage(let coverStrip): titlePage(coverStrip: coverStrip)
        }
    }

    private static let barWidths: [CGFloat] = [150, 120, 170, 100, 135]
    /// Studios' rows: a 15 pt bold name and a count, a thin bar under them, 14 pt apart.
    private func bars(_ rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<max(1, rows), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Text(" ").font(.app(size: 15, weight: .bold)).lineLimit(1).hidden().frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            HStack {
                                Capsule().fill(line).frame(width: Self.barWidths[index % Self.barWidths.count], height: 11)
                                Spacer()
                                Capsule().fill(faint).frame(width: 18, height: 9)
                            }
                        }
                    Capsule().fill(faint).frame(height: 8)
                }
            }
        }
    }
    /// The shelf's portraits (0.83 wide to tall, a column ~2.85 to the screen), a 16 pt name and a
    /// 13 pt line, as `MostWatchedShelf` lays them out.
    private var peopleShelf: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill).aspectRatio(0.83, contentMode: .fit).padding(.bottom, 6)
                        Text(" ").font(.app(size: 16, weight: .bold)).lineLimit(1).hidden().frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .leading) { Capsule().fill(line).frame(height: 11).padding(.trailing, 24) }
                        Text(" ").font(.app(size: 13)).lineLimit(1).hidden().frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .leading) { Capsule().fill(faint).frame(width: 50, height: 9) }
                    }
                    .containerRelativeFrame(.horizontal) { width, _ in min(150, max(100, (width - 36) / 2.85)) }
                }
            }
        }.scrollDisabled(true).scrollIndicators(.hidden)
    }
    /// The round row: 64 pt photos, a 13 pt name and a 12 pt count, the last place See all.
    private var peopleRound: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                VStack(spacing: 6) {
                    Circle().fill(fill).frame(width: 64, height: 64)
                    Text(" ").font(.app(size: 13, weight: .semibold)).lineLimit(1).hidden()
                        .overlay { Capsule().fill(line).frame(width: 52, height: 10) }
                    if index < 3 {
                        Text(" ").font(.app(size: 12)).lineLimit(1).hidden().overlay { Capsule().fill(faint).frame(width: 30, height: 8) }
                    }
                }.frame(maxWidth: .infinity)
            }
        }
    }
    private func cards(_ count: Int, height: CGFloat) -> some View {
        VStack(spacing: 14) {
            ForEach(0..<max(1, count), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill).frame(height: height)
            }
        }
    }

    private var block: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill).frame(height: max(44, height - 80))
                Capsule().fill(line).frame(width: geometry.size.width * 0.72, height: 12)
                Capsule().fill(faint).frame(width: geometry.size.width * 0.48, height: 10)
            }
        }.frame(height: height)
    }

    private func list(_ rows: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<max(1, rows), id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill).frame(width: 48, height: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        Capsule().fill(line).frame(width: index.isMultiple(of: 2) ? 190 : 150, height: 12)
                        Capsule().fill(faint).frame(width: index.isMultiple(of: 3) ? 90 : 120, height: 10)
                    }
                    Spacer(minLength: 0)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(columns: Int, rows: Int) -> some View {
        VStack(spacing: 16) {
            ForEach(0..<max(1, rows), id: \.self) { _ in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<max(1, columns), id: \.self) { _ in poster }
                }
            }
        }.frame(maxWidth: .infinity)
    }

    private var poster: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: Studio.corner(Gap.posterCorner), style: .continuous).fill(fill).posterAspect()
            Capsule().fill(line).frame(height: 10).padding(.trailing, 18)
            Capsule().fill(faint).frame(width: 40, height: 8)
        }.frame(maxWidth: .infinity)
    }

    /// The shelf's own geometry (a sideways scroll view holding column-wide posters), so the real
    /// posters land exactly where the shapes were and nothing under the shelf moves.
    private func shelf(oneLine: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                // Enough at Shelf cards' width to fill the screen and run off its edge (the shelf clips them).
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        RoundedRectangle(cornerRadius: Studio.corner(Gap.posterCorner), style: .continuous).fill(fill).posterAspect()
                        if TilePrefs.shared.posterCaptions { caption(oneLine: oneLine) }
                    }.frame(width: posterSize.shelf)
                }
            }
        }.scrollDisabled(true).scrollIndicators(.hidden)
    }
    /// The caption's height comes from hidden text in the real fonts (it follows Dynamic Type as the
    /// real caption does); the grey bars sit over it.
    private func caption(oneLine: Bool) -> some View {
        Group {
            if oneLine {
                VStack(alignment: .leading, spacing: 0) {
                    Text(" ").font(.app(size: 15, weight: .semibold)).lineLimit(1).frame(minHeight: 20.25).padding(.top, 8)
                    Text(" ").font(.app(size: 12)).lineLimit(1).frame(height: 18).padding(.top, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(" ").font(.app(size: 15, weight: .semibold)).lineLimit(2, reservesSpace: true).padding(.top, 8)
                    Text(" ").font(.app(size: 13)).lineLimit(1).padding(.top, 3)
                }
            }
        }.hidden().frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .topLeading) { captionBars }
    }
    private var captionBars: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(line).frame(height: 10).padding(.trailing, 18)
            Capsule().fill(faint).frame(width: 40, height: 8)
        }.padding(.top, 11)
    }
    /// Home's posters: a fixed width, a 14 pt name on two lines and a 12 pt details line.
    private var homeShelf: some View {
        let width = posterSize.homeWidth
        return HStack(alignment: .top, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    RoundedRectangle(cornerRadius: Studio.corner(Gap.posterCorner), style: .continuous).fill(fill).frame(width: width, height: width * 1.5)
                    if TilePrefs.shared.posterCaptions {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(" ").font(.app(size: 14, weight: .semibold)).lineLimit(2, reservesSpace: true).padding(.top, 9)
                            Text(" ").font(.app(size: 12)).lineLimit(1).padding(.top, 3)
                        }.hidden().frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .topLeading) { captionBars }
                    }
                }.frame(width: width)
            }
        // minWidth 0: four posters are wider than the phone's column; without it the shelf took their
        // width and stretched the page past the screen while it loaded.
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
    }

    /// As `TitleHero` lays it out: the cover strip (the screen's width), then 20 pt apart the 112 × 168
    /// poster with the name 8 pt below its top, the ratings bar and four lines of synopsis.
    private func titlePage(coverStrip: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(faint).frame(height: max(0, coverStrip - 6)).padding(.horizontal, -16).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fill).frame(width: 112, height: 168)
                    VStack(alignment: .leading, spacing: 10) {
                        Capsule().fill(line).frame(width: 170, height: 22)
                        Capsule().fill(faint).frame(width: 130, height: 12)
                        HStack(spacing: 6) {
                            Capsule().fill(faint).frame(width: 70, height: 30)
                            Capsule().fill(faint).frame(width: 58, height: 30)
                        }.padding(.top, 2)
                    }.padding(.top, 8)
                }
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill).frame(height: 46)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<4, id: \.self) { index in Capsule().fill(faint).frame(height: 10).padding(.trailing, index == 3 ? 110 : 0) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(fill).frame(width: 128, height: 186)
                VStack(alignment: .leading, spacing: 12) {
                    Capsule().fill(line).frame(width: 150, height: 18)
                    Capsule().fill(faint).frame(width: 90, height: 12)
                    Capsule().fill(faint).frame(width: 120, height: 12).padding(.top, 14)
                    Capsule().fill(faint).frame(width: 70, height: 12)
                }.padding(.top, 40)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<4, id: \.self) { index in Capsule().fill(faint).frame(height: 10).padding(.trailing, index == 3 ? 120 : 0) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grey shapes built by hand for one card (when no layout above fits), pulsing as
/// `DiaryLoadingPlaceholder`'s do.
extension View {
    func loadingPulse(_ label: String) -> some View { modifier(LoadingPulse(label: label)) }
}
private struct LoadingPulse: ViewModifier {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.45]) { view, strength in view.opacity(strength) } animation: { _ in .easeInOut(duration: 0.9) }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
/// The placeholders' iOS fill colours, for hand-built ones.
enum SkeletonFill {
    static var fill: Color { Color(uiColor: .tertiarySystemFill) }
    static var line: Color { Color(uiColor: .systemFill) }
}
