import SwiftUI
import PhotosUI
import TwilDiaryCore

struct PersonalAvatar: View {
    var profile = PersonalProfile.shared
    var size: CGFloat = 52
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    var body: some View {
        Group {
            if profile.usesPhoto, let image = profile.photo { Image(uiImage: image).resizable().scaledToFill() }
            else if let character = profile.character { Artwork(path: character.image, title: character.name) }
            else { Text(String(profile.name.prefix(1)).uppercased()).font(.system(size: size * 0.4, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.accent.opacity(0.2)) }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct PersonalProfileView: View {
    @Environment(DiaryStore.self) private var store
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @Environment(\.dynamicTypeSize) private var typeSize
    private var profile = PersonalProfile.shared
    @State private var characters: [ProfileAvatarChoice] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showAvatarPicker = false
    @State private var editing = false
    @State private var draftName = ""
    var body: some View {
        let milestones = ProfileMilestone.make(store.workspace, now: store.now)
        EdgeToEdgeScroll {
            VStack(alignment: .leading, spacing: 26) {
                VStack(spacing: 10) {
                    Button { showAvatarPicker = true } label: {
                        PersonalAvatar(size: 100).overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill").font(.caption).padding(7).background(theme.field, in: Circle()).foregroundStyle(.primary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Change profile picture").accessibilityIdentifier("profile-avatar")
                    Text(profile.name).font(.title2.bold())
                }.frame(maxWidth: .infinity).padding(.top, 10)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Popular Characters").font(.title3.bold())
                    if loading && characters.isEmpty { ProgressView("Loading characters") }
                    if let error { VStack(alignment: .leading) { Text(error).font(.footnote).foregroundStyle(.secondary); Button("Retry") { Task { await loadCharacters() } } } }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(characters) { choice in ProfileCharacterAvatarButton(choice: choice, size: 76) { profile.select(choice) } }
                        }.padding(.vertical, 3)
                    }.scrollIndicators(.hidden).accessibilityIdentifier("profile-popular-characters")
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Milestones").font(.title3.bold()); Spacer(); Text("\(milestones.filter(\.earned).count) earned").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: typeSize.isAccessibilitySize ? 2 : 3), alignment: .leading, spacing: 24) {
                        ForEach(milestones) { badge($0) }
                    }
                    Text("Based on your watch history. Watch-time milestones use dated watches with known runtimes.")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("profile-milestones")
            }.padding(16).padding(.bottom, 24)
        }.diaryScreenBackground().navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { draftName = profile.name; editing = true }.accessibilityIdentifier("profile-edit-name") } }
            .alert("Profile name", isPresented: $editing) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) { }
                Button("Save") { profile.rename(draftName) }.disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { Text("Your name and avatar are saved on this device.") }
            .sheet(isPresented: $showAvatarPicker) { NavigationStack { AvatarPickerView(characters: characters) }.presentationDragIndicator(.visible) }
            .task { await loadCharacters() }
    }
    private func loadCharacters() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            #if DEBUG
            if store.isPreview { characters = [ProfileAvatarChoice(id: 176754, name: "Frieren", image: "/demo/frieren.jpg"), ProfileAvatarChoice(id: 138100, name: "Anya", image: nil)]; return }
            #endif
            let values = try await AniListClient.shared.popularAvatars()
            guard !Task.isCancelled else { return }; characters = values
        } catch { if !Task.isCancelled { self.error = "Characters are unavailable. You can still choose a custom photo by tapping your avatar." } }
    }
    private func badge(_ value: ProfileMilestone) -> some View {
        let colour = Color(webHex: value.colour)
        return VStack(spacing: 8) {
            Image(systemName: value.symbol).font(.system(size: 24, weight: .light)).foregroundStyle(colour.opacity(value.earned ? 1 : 0.5))
                .frame(width: 54, height: 54).background(colour.opacity(0.06), in: Circle()).overlay(Circle().strokeBorder(colour.opacity(value.earned ? 0.6 : 0.2)))
                .overlay(alignment: .bottomTrailing) { if value.earned { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(theme.accent).background(.black, in: Circle()) } }
            Text(value.title).font(.caption.weight(.medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(value.earned ? "Earned" : value.progressLabel).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
            .accessibilityLabel(value.title + ", " + (value.earned ? "Earned" : value.progressLabel))
    }
}

private struct AvatarPickerView: View {
    let characters: [ProfileAvatarChoice]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    @State private var selection: PhotosPickerItem?
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        let fieldColour = theme.field
        EdgeToEdgeScroll {
            VStack(spacing: 22) {
                PersonalAvatar(size: 112)
                PhotosPicker(selection: $selection, matching: .images) {
                    Label("Choose custom photo", systemImage: "photo.badge.plus").frame(maxWidth: .infinity, minHeight: 48).background(fieldColour, in: RoundedRectangle(cornerRadius: 12))
                }.disabled(loading).accessibilityIdentifier("profile-custom-photo")
                if loading { ProgressView("Preparing photo") }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Button("Use initials") { generation = UUID(); PersonalProfile.shared.useInitials(); dismiss() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85))], spacing: 20) {
                    ForEach(characters) { choice in
                        ProfileCharacterAvatarButton(choice: choice, size: 72) {
                            generation = UUID(); PersonalProfile.shared.select(choice); dismiss()
                        }
                    }
                }
            }.padding(20)
        }.diaryScreenBackground().navigationTitle("Avatar").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: selection) {
                guard let selection else { return }; let request = UUID(); generation = request; loading = true; error = nil
                defer { if generation == request { loading = false } }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self), !Task.isCancelled, generation == request else { return }
                    try PersonalProfile.shared.savePhoto(data); dismiss()
                } catch { if !Task.isCancelled && generation == request { self.error = error.localizedDescription } }
            }
            .onDisappear { generation = UUID() }
    }
}

/// Explicit accessibility on the control keeps decorative Artwork from hiding
/// the avatar option, and observes selection in each small leaf's own body.
private struct ProfileCharacterAvatarButton: View {
    let choice: ProfileAvatarChoice
    let size: CGFloat
    let choose: () -> Void
    @AppStorage("theme") private var theme = DiaryTheme.twilight
    private var profile: PersonalProfile { .shared }
    var body: some View {
        let selected = !profile.usesPhoto && profile.character?.id == choice.id
        Button(action: choose) {
            VStack(spacing: 6) {
                Artwork(path: choice.image, title: choice.name).frame(width: size, height: size).clipShape(Circle())
                    .overlay(Circle().strokeBorder(selected ? theme.accent : .clear, lineWidth: 3))
                Text(choice.name).font(.caption).lineLimit(2).frame(width: size)
            }.foregroundStyle(.primary)
        }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityHidden(false)
            .accessibilityLabel("Use " + choice.name + " as avatar").accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("profile-character-\(choice.id)")
    }
}
