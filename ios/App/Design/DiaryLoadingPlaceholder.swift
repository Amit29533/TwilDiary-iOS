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
}

/// What shows while something loads: grey shapes laid out like the content that's coming, gently
/// pulsing, as Apple's own apps show loading (no spinner rows that push the page about). The same in
/// every theme. Background refreshes keep the loaded content instead. Still under Reduce Motion.
struct DiaryLoadingPlaceholder: View {
    var height: CGFloat = 160
    var label = "Loading content"
    var layout: PlaceholderLayout = .block
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PosterSize.key) private var posterSize = PosterSize.regular
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
                ForEach(0..<(posterSize.columns + 1), id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        RoundedRectangle(cornerRadius: Studio.corner(Gap.posterCorner), style: .continuous).fill(fill).posterAspect()
                        if TilePrefs.shared.posterCaptions { caption(oneLine: oneLine) }
                    }.containerRelativeFrame(.horizontal, count: posterSize.columns, spacing: 12)
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
