import SwiftUI
import UIKit
import ImageIO
import Observation

struct ProfileAvatarChoice: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let image: String?
}

/// Personal appearance is local to this device, separate from AniList favourites
/// and from the hosted diary. A selected photo is normalized and stored privately.
@MainActor @Observable final class PersonalProfile {
    static let shared = PersonalProfile()
    private let defaults: UserDefaults
    private let photoURL: URL
    private(set) var name: String
    private(set) var character: ProfileAvatarChoice?
    private(set) var photo: UIImage?
    private(set) var usesPhoto: Bool
    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let folder = directory ?? URL.applicationSupportDirectory.appendingPathComponent("PersonalProfile", isDirectory: true)
        photoURL = folder.appendingPathComponent("avatar.jpg")
        name = defaults.string(forKey: "profileName") ?? "Amit"
        character = defaults.data(forKey: "profileCharacter").flatMap { try? JSONDecoder().decode(ProfileAvatarChoice.self, from: $0) }
        usesPhoto = defaults.bool(forKey: "profileUsesPhoto")
        photo = UIImage(contentsOfFile: photoURL.path)
    }
    func rename(_ input: String) {
        let value = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !value.isEmpty else { return }
        name = value; defaults.set(value, forKey: "profileName")
    }
    func select(_ choice: ProfileAvatarChoice) {
        character = choice; usesPhoto = false
        defaults.set(try? JSONEncoder().encode(choice), forKey: "profileCharacter")
        defaults.set(false, forKey: "profileUsesPhoto")
    }
    func useInitials() {
        character = nil; usesPhoto = false
        defaults.removeObject(forKey: "profileCharacter"); defaults.set(false, forKey: "profileUsesPhoto")
    }
    func savePhoto(_ data: Data) throws {
        guard data.count <= 30_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw APIError.message("Choose a valid image up to 30 MB.") }
        let image = UIImage(cgImage: thumbnail)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let scale = max(512 / image.size.width, 512 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (512 - size.width) / 2, y: (512 - size.height) / 2, width: size.width, height: size.height))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: 0.88) else { throw APIError.message("This photo could not be opened.") }
        try FileManager.default.createDirectory(at: photoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: photoURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        photo = normalized; usesPhoto = true; defaults.set(true, forKey: "profileUsesPhoto")
    }
}
