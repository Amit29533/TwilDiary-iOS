import XCTest
import UIKit
@testable import TwilDiary

@MainActor final class PersonalProfileTests: XCTestCase {
    func testNameAndCharacterPersistAndInitialsClearSelection() throws {
        let suite = "profile-test-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let value = PersonalProfile(defaults: defaults, directory: directory)
        value.rename("  Test name  "); value.rename("   ")
        value.select(ProfileAvatarChoice(id: 176754, name: "Frieren", image: nil))
        let restored = PersonalProfile(defaults: defaults, directory: directory)
        XCTAssertEqual(restored.name, "Test name"); XCTAssertEqual(restored.character?.id, 176754); XCTAssertFalse(restored.usesPhoto)
        restored.useInitials()
        XCTAssertNil(PersonalProfile(defaults: defaults, directory: directory).character)
    }
    func testPhotoIsNormalizedPersistedAndInvalidReplacementKeepsPreviousAvatar() throws {
        let suite = "photo-test-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let value = PersonalProfile(defaults: defaults, directory: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 1200)).image { context in UIColor.purple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200)) }
        try value.savePhoto(try XCTUnwrap(image.pngData()))
        XCTAssertEqual(value.photo?.size, CGSize(width: 512, height: 512)); XCTAssertTrue(value.usesPhoto)
        XCTAssertThrowsError(try value.savePhoto(Data("invalid image".utf8)))
        let restored = PersonalProfile(defaults: defaults, directory: directory)
        XCTAssertTrue(restored.usesPhoto); XCTAssertEqual(restored.photo?.size, CGSize(width: 512, height: 512))
        restored.select(ProfileAvatarChoice(id: 1, name: "Character", image: nil)); XCTAssertFalse(restored.usesPhoto)
    }
    func testStatisticsShortcutUsesTheProfileStackAndSearchKeepsItsOwnStack() {
        let router = AppRouter(); router.selectedTab = .home
        router.statsToday()
        XCTAssertEqual(router.selectedTab, .more); XCTAssertEqual(router.paths[.more]?.count, 1)
        XCTAssertEqual(router.statsRevision, 1)
        router.search(); XCTAssertEqual(router.selectedTab, .search); XCTAssertEqual(router.paths[.more]?.count, 1)
        XCTAssertEqual(AppTab.allCases.map(\.label), ["Home", "Library", "Glance", "Search", "Profile"])
    }
}
