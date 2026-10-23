import SwiftUI
import TwilDiaryCore

enum DiaryTheme: String, CaseIterable, Identifiable {
    case twilight, ocean, jade, rose, amber, glass
    var id: Self { self }
    var name: String { self == .glass ? "Liquid Glass" : rawValue.capitalized }
    var accent: Color {
        switch self {
        case .twilight: Color(red: 183/255, green: 149/255, blue: 246/255)
        case .ocean: Color(red: 130/255, green: 184/255, blue: 1)
        case .jade: Color(red: 121/255, green: 216/255, blue: 188/255)
        case .rose: Color(red: 244/255, green: 162/255, blue: 198/255)
        case .amber: Color(red: 237/255, green: 190/255, blue: 115/255)
        case .glass: Color(red: 196/255, green: 229/255, blue: 1)
        }
    }
}

extension View {
    func diaryPanel() -> some View {
        self.padding(16).background(Color(red: 0.065, green: 0.065, blue: 0.082), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.09)))
    }
}

struct PageHeader: View {
    let name: String
    var count: String? = nil
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle").font(.title2).foregroundStyle(theme.accent)
                .frame(width: 44, height: 44).background(theme.accent.opacity(0.1), in: Circle())
                .overlay(Circle().strokeBorder(theme.accent.opacity(0.25)))
            if name == "TwilDiary" {
                HStack(spacing: 0) {
                    Text("Twil").foregroundStyle(.white)
                    Text("Diary").foregroundStyle(LinearGradient(colors: [.white, theme.accent], startPoint: .leading, endPoint: .trailing))
                }.font(.system(size: 28, weight: .bold)).tracking(-1)
            } else {
                Text(name).font(.system(size: 28, weight: .bold)).tracking(-1).foregroundStyle(.white)
            }
            if let count { Text(count).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
    }
}

struct Artwork: View {
    let path: String?
    var title: String = ""
    var body: some View {
        ZStack {
            LinearGradient(colors: [.purple.opacity(0.45), Color(white: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let path, path.hasPrefix("asset:"), let file = Bundle.main.path(forResource: String(path.dropFirst(6)), ofType: "jpg"), let image = UIImage(contentsOfFile: file) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let path, let url = URL(string: path), url.scheme == "https" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { initials }
                }
            } else { initials }
        }.clipped().accessibilityHidden(true)
    }
    private var initials: some View {
        Text(title.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
            .font(.title.bold()).foregroundStyle(.white.opacity(0.7))
    }
}

struct PosterCard: View {
    let title: MediaTitle
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Artwork(path: title.poster, title: title.name).aspectRatio(2/3, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if let score = title.communityScore, score > 0 {
                        HStack(spacing: 3) { Image(systemName: "star.fill").foregroundStyle(.yellow); Text(score, format: .number.precision(.fractionLength(1))) }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.black.opacity(0.65), in: Capsule()).padding(6)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 13))
            Text(title.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            if let year = title.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

struct CategoryPicker: View {
    @Binding var selection: LibraryCategory
    var body: some View {
        HStack(spacing: 0) {
            ForEach(LibraryCategory.allCases) { category in
                Button { selection = category } label: {
                    Text(category.rawValue).font(.system(size: 15, weight: .semibold)).foregroundStyle(selection == category ? .primary : .secondary)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .overlay(alignment: .bottom) { if category == selection { Rectangle().fill(.tint).frame(height: 3) } }
                }.buttonStyle(.plain).accessibilityAddTraits(selection == category ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 4)
    }
}

struct SectionHeading<Trailing: View>: View {
    let name: String
    @ViewBuilder var trailing: Trailing
    var body: some View { HStack { Text(name).font(.title3.bold()); Spacer(minLength: 4); trailing.font(.subheadline.weight(.semibold)) } }
}

struct ProgressCard: View {
    let title: MediaTitle
    var compact = false
    @Environment(DiaryStore.self) private var store
    @State private var card: WatchCard?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 13) {
                NavigationLink(value: title.id) {
                    Artwork(path: title.poster, title: title.name).frame(width: compact ? 54 : 88, height: compact ? 81 : 132).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: title.id) { Text(title.name).font(.system(size: compact ? 17 : 20, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    if let card {
                        HStack(spacing: 4) {
                            if let season = card.season { Text("S\(season.number) · E\(card.progress.watched) of \(card.progress.total)") }
                            if let remaining { Text("· \(DiaryDate.duration(remaining)) left").foregroundStyle(Color(white: 0.75)).shadow(color: .black, radius: 3) }
                        }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.82)).fixedSize(horizontal: false, vertical: true)
                    } else { Text(title.categoryName).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 15) {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: fraction)
                    Text("\(Int((fraction * 100).rounded()))% complete").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await store.removeLatest(title); await loadCard() } } label: { Image(systemName: "minus").frame(width: 28, height: 28) }
                    .buttonStyle(.bordered).disabled(store.busy || card?.previous == nil).accessibilityLabel("Remove latest watch for \(title.name)")
                Button { Task { await store.markNext(title); await loadCard() } } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.borderedProminent).disabled(store.busy || (title.isSeries && card?.next == nil)).accessibilityLabel("Mark next watch for \(title.name)")
            }
        }.padding(14)
            .background {
                GeometryReader { geometry in
                    Artwork(path: title.backdrop, title: title.name).frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(LinearGradient(colors: [.black.opacity(0.48), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.18)))
            .task(id: store.workspace.events) { await loadCard() }
    }
    private var fraction: Double { guard let card, card.progress.total > 0 else { return 0 }; return Double(card.progress.watched) / Double(card.progress.total) }
    private var remaining: Int? {
        guard let card else { return nil }
        if !title.isSeries { return title.runtimeMinutes.map { card.progress.watched == 0 ? $0 : 0 } }
        return SeasonProgress.calculate(title: title, workspace: store.workspace, season: card.season?.number ?? 1).remainingMinutes
    }
    private func loadCard() async {
        guard !store.isPreview else { card = PreviewData.card; return }
        do { card = try await store.card(title) } catch { /* Page-level Refresh exposes transport failures; never fabricate progress. */ }
    }
}
