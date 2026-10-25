import SwiftUI

/// Layout and sample artwork follow ThemePicker.svelte, including the phone's two-column grid.
struct AppearanceView: View {
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var showSearch = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 11, alignment: .top), count: 2)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showSearch { CatalogSearchView(onClose: { showSearch = false }).padding(.horizontal, -14) }
                    VStack(alignment: .leading, spacing: 0) {
                        heading.padding(.bottom, 20)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 11) {
                            ForEach(DiaryTheme.allCases) { item in
                                Button { theme = item } label: { ThemeOption(item: item, selected: item == theme) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.name + ": " + item.detail)
                                    .accessibilityIdentifier("theme-" + item.rawValue)
                                    .accessibilityAddTraits(item == theme ? .isSelected : [])
                            }
                        }
                        Text("Changes instantly · saved on this device")
                            .font(.system(size: 11.2)).foregroundStyle(theme.muted).frame(minHeight: 16.8)
                            .padding(.top, 15)
                    }.diaryPanel(padding: 19, radius: 22)
                }.padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 24)
            }
        }.diaryScreenBackground().diaryPageNavigation("Appearance", searchIdentifier: "search-appearance") { showSearch.toggle() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DiaryIcon(name: "sparkles", size: 14)
                Text("MAKE IT YOURS").font(.system(size: 9.92, weight: .heavy)).tracking(1.19)
            }.frame(height: 14.88).foregroundStyle(theme.accent).padding(.bottom, 7)
            Text("Appearance").font(.system(size: 21.6, weight: .bold)).tracking(-0.86).frame(minHeight: 25.92)
            Text("A different mood. The same diary.").font(.system(size: 13.12))
                .foregroundStyle(theme.muted).frame(minHeight: 19.68).padding(.top, 5)
        }
    }
}

private struct ThemeOption: View {
    let item: DiaryTheme
    let selected: Bool
    @AppStorage("theme") private var theme = DiaryTheme.twilight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemeMiniature(item: item, selected: selected)
            HStack(spacing: 6) {
                Circle().fill(item.accent).frame(width: 8, height: 8)
                Text(item.name).font(.system(size: 13.12, weight: .semibold))
            }.frame(minHeight: 19.68).padding(.horizontal, 3).padding(.top, 9)
            Text(item.detail).font(.system(size: 10.4)).foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 14.56, alignment: .leading)
                .padding(.horizontal, 3).padding(.top, 3)
        }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(theme.text)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? item.accent : .white.opacity(0.13), lineWidth: selected ? 2 : 1))
            .accessibilityElement(children: .ignore)
    }
}

private struct ThemeMiniature: View {
    let item: DiaryTheme
    let selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                BrandMark().fill(item.accent).frame(width: 10, height: 10)
                Capsule().fill(Color(webHex: "#f3f0f7d9")).frame(width: 40, height: 5)
                Spacer(minLength: 0)
                Circle().strokeBorder(.white.opacity(0.44)).frame(width: 5, height: 5)
            }.frame(height: 18).padding(.bottom, 10)
            sampleCard
            sampleNavigation.padding(.top, 7)
        }.padding(12).fixedSize(horizontal: false, vertical: true)
            .frame(height: 112, alignment: .top)
            .frame(maxWidth: .infinity)
            .background {
                Color.black
                if item == .glass {
                    RadialGradient(colors: [.white.opacity(0.075), .clear], center: .topLeading, startRadius: 0, endRadius: 120)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.03)))
            .overlay(alignment: .topTrailing) { selectionMark.padding(7) }
            .accessibilityHidden(true)
    }

    private var sampleCard: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [item.strong, item.ink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 23, height: 33)
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 5) {
                    Capsule().fill(.white.opacity(0.7)).frame(width: geometry.size.width * 0.75, height: 4)
                    Capsule().fill(.white.opacity(0.25)).frame(width: geometry.size.width * 0.45, height: 3)
                    Capsule().fill(.white.opacity(0.1)).frame(height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(item.accent).frame(width: geometry.size.width * 0.61) }
                        .padding(.top, 4)
                }.frame(height: 33)
            }.frame(height: 33)
        }.padding(9).background { sampleSurface }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(item == .glass ? 0.21 : 0.075)))
    }

    private var sampleNavigation: some View {
        HStack(spacing: 8) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 2).fill(index == 0 ? item.accent : .white.opacity(0.33))
                    .frame(width: 6, height: 6)
                    .background {
                        if index == 0 { RoundedRectangle(cornerRadius: 4).fill(item.ink).padding(-3) }
                    }.frame(maxWidth: .infinity)
            }
        }.padding(.horizontal, 10).padding(.vertical, 6)
            .background { if item == .glass { sampleSurface } else { Color.white.opacity(0.024) } }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(item == .glass ? 0.21 : 0)))
    }

    @ViewBuilder private var sampleSurface: some View {
        if item == .glass {
            LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else { Color(webHex: "#111115") }
    }

    private var selectionMark: some View {
        ZStack {
            Circle().fill(selected ? item.accent : Color(webHex: "#0c1016"))
            Circle().strokeBorder(selected ? item.accent : .white.opacity(0.125))
            if selected { DiaryIcon(name: "check", size: 14).foregroundStyle(item.ink) }
        }.frame(width: 20, height: 20)
    }
}
