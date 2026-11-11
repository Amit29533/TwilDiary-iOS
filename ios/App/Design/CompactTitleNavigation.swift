import SwiftUI
import UIKit
import TwilDiaryCore

/// Only the small toolbar leaves observe scrolling. Keeping this reference in
/// the detail screen avoids invalidating every episode and cast cell per frame.
@MainActor @Observable final class CompactHeaderState {
    private(set) var progress: CGFloat = 0
    func update(_ value: CGFloat) {
        let next = value.isFinite ? min(1, max(0, value)) : 0
        guard next != progress else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { progress = next }
    }
}

/// Content-sized identity inside the system navigation bar. The system retains
/// Back/interactive transitions and owns safe-area geometry during scrolling.
struct CompactTitleNavigation: View {
    let name: String
    let poster: String?
    let state: CompactHeaderState
    private var progress: CGFloat { state.progress }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            Artwork(path: poster, title: name, initialsOnly: false).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 9))
            Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }.frame(height: 28)
            .opacity(Double(progress))
            .offset(y: reduceMotion ? 0 : (1 - progress) * 6)
            .accessibilityElement(children: .ignore).accessibilityLabel(name).accessibilityIdentifier("compact-title-navigation")
            .accessibilityHidden(progress < 0.5)
    }
}

/// A page title that hands over to the heading as it scrolls under the bar (Explore, a person's
/// lists): the same scroll-linked fade and small lift as a title page's name, never a swap.
struct ScrollLinkedBarTitle: View {
    let resting: String
    let scrolled: String
    let state: CompactHeaderState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let progress = state.progress
        ZStack {
            Text(resting).opacity(Double(1 - progress)).offset(y: reduceMotion ? 0 : -progress * 6)
                .accessibilityHidden(progress >= 0.5)
            Text(scrolled).opacity(Double(progress)).offset(y: reduceMotion ? 0 : (1 - progress) * 6)
                .accessibilityHidden(progress < 0.5)
        }.font(.system(size: 17, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1).truncationMode(.tail)
            .accessibilityAddTraits(.isHeader)
    }
    /// From the heading's bottom edge on screen: 0 while it's in view, 1 once it's under the bar.
    static func progress(headingBottom: CGFloat) -> CGFloat {
        guard headingBottom.isFinite else { return 0 }
        let value = min(1, max(0, (130 - headingBottom) / 70))
        return (value * 32).rounded() / 32
    }
}

/// Ignore the crossing band: toolbar layout and a reversing scroll must not
/// repeatedly insert/remove the title at the same single-pixel threshold.
enum CompactHeaderTransition {
    static func progress(nameBottom: CGFloat) -> CGFloat {
        guard nameBottom.isFinite else { return 0 }
        // Fade over 80 points of real scroll. Quantization limits body work;
        // there is no animation repeatedly chasing a reversing finger.
        let value = min(1, max(0, (48 - nameBottom) / 80))
        return (value * 32).rounded() / 32
    }
}

struct CompactHeaderBackdrop: View {
    let state: CompactHeaderState
    let topInset: CGFloat
    var body: some View {
        FeatheredHeaderBackdrop(state: state, height: topInset).offset(y: -topInset)
    }
}

/// One native toolbar button owns the crossfade. Stacking two interactive
/// toolbar controls can leave the invisible control intercepting the share tap.
struct TitleHeaderAction: View {
    let name: String
    let kind: MediaKind
    let id: Int?
    let state: CompactHeaderState
    @Binding var informationPresented: Bool
    var informationIdentifier = "title-information"
    /// False on saved titles: they open Sentiments from the ··· menu, so only share shows (once scrolled).
    var showsInformation = true
    /// Saved titles: the heart, which share replaces in the same slot once the page scrolls.
    var favorite: Bool? = nil
    var onFavorite: (() -> Void)? = nil
    @State private var sharing = false
    private var progress: CGFloat { state.progress }
    private var compact: Bool { progress >= 0.5 }
    var body: some View {
        if let favorite, let onFavorite {
            // One slot: the heart at the top of the page, share once the title moves into the bar.
            Button {
                if compact { sharing = true } else { onFavorite() }
            } label: {
                ZStack {
                    Image(systemName: "square.and.arrow.up").opacity(Double(progress))
                    Image(systemName: favorite ? "heart.fill" : "heart").opacity(Double(1 - progress))
                }.frame(width: 32, height: 32)
            }.accessibilityLabel(compact ? "Share " + name : favorite ? "Remove favorite" : "Favorite")
                .accessibilityIdentifier(compact ? "title-share" : "title-favorite")
                .sheet(isPresented: $sharing) { TitleActivitySheet(name: name, kind: kind, id: id) }
        } else if showsInformation || compact {
            Button {
                if compact || !showsInformation { sharing = true } else { informationPresented = true }
            } label: {
                ZStack {
                    Image(systemName: "square.and.arrow.up").opacity(showsInformation ? Double(progress) : 1)
                    if showsInformation { Image(systemName: "info.circle").opacity(Double(1 - progress)) }
                }.frame(width: 32, height: 32)
            }.accessibilityLabel(compact || !showsInformation ? "Share " + name : "Sentiments")
                .accessibilityIdentifier(compact || !showsInformation ? "title-share" : informationIdentifier)
                .sheet(isPresented: $sharing) { TitleActivitySheet(name: name, kind: kind, id: id) }
        }
    }
}

@MainActor private struct TitleActivitySheet: UIViewControllerRepresentable {
    let name: String
    let kind: MediaKind
    let id: Int?
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let item: Any
        if let id, id > 0, let url = URL(string: "https://www.themoviedb.org/\(kind == .tv ? "tv" : "movie")/\(id)") { item = url }
        else { item = name }
        return UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The title pages' one top-right button (owner's design): a 44 pt dark circle with three white
/// dots. Its menu holds everything else (Sentiments, Favourite, Queue, Notes, Files, Share, Trash).
struct TitleMoreButtonLabel: View {
    /// Title pages: clear Liquid Glass over the artwork (the owner's choice for this button).
    /// Elsewhere (glass: false): the dark round button.
    var glass = true
    var body: some View {
        let icon = Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).contentShape(Circle())
        if glass {
            // In the bar, the system's glass (same as the back button) draws around it.
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
        } else {
            icon.background(Color(webHex: "#2b2b30").opacity(0.94), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.67))
        }
    }
}

/// "Share" in a title's menu: its TMDB page, or just its name when it has no TMDB id.
struct TitleShareItem: View {
    let name: String
    let kind: MediaKind
    let id: Int?
    var body: some View {
        if let id, id > 0, let url = URL(string: "https://www.themoviedb.org/\(kind == .tv ? "tv" : "movie")/\(id)") {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("title-share")
        } else {
            ShareLink(item: name) { Label("Share", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("title-share")
        }
    }
}
