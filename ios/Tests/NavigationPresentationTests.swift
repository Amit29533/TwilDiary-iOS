import XCTest
import SwiftUI
import UIKit
@testable import TwilDiary

/// Exercise UIKit containment, rather than assuming representable controller
/// parentage is identical to the hosting view's attachment.
@MainActor final class NavigationPresentationTests: XCTestCase {
    func testPresentedChildPublishesDetailAndPoppingRestoresRootChrome() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let router = AppRouter()
        router.detailTabs.insert(.home)
        let root = UIHostingController(rootView: Color.black.diaryNavigationAppearance(tab: .home, detail: false, router: router))
        let navigation = UINavigationController(rootViewController: root)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let rootAppeared = await waitForDetail(false, router: router)
        XCTAssertTrue(rootAppeared)
        let detail = UIHostingController(rootView: Color.blue.diaryNavigationAppearance(tab: .home, detail: true, router: router))
        navigation.pushViewController(detail, animated: false)
        let detailAppeared = await waitForDetail(true, router: router)
        XCTAssertTrue(detailAppeared)
        _ = navigation.popViewController(animated: false)
        let rootReturned = await waitForDetail(false, router: router)
        XCTAssertTrue(rootReturned)
    }
    func testUpdatingAnOffscreenRootCannotRevealItsChromeOverTheDetail() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let router = AppRouter()
        router.detailTabs.insert(.home)
        let root = UIHostingController(rootView: Color.black.diaryNavigationAppearance(tab: .home, detail: false, router: router))
        let navigation = UINavigationController(rootViewController: root)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let rootAppeared = await waitForDetail(false, router: router)
        XCTAssertTrue(rootAppeared)
        let detail = UIHostingController(rootView: Color.blue.diaryNavigationAppearance(tab: .home, detail: true, router: router))
        navigation.pushViewController(detail, animated: false)
        let detailAppeared = await waitForDetail(true, router: router)
        XCTAssertTrue(detailAppeared)
        root.rootView = Color.red.diaryNavigationAppearance(tab: .home, detail: false, router: router)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(router.detailTabs.contains(.home))
        XCTAssertTrue(navigation.topViewController === detail)
    }
    private func waitForDetail(_ expected: Bool, router: AppRouter) async -> Bool {
        for _ in 0..<100 {
            if router.detailTabs.contains(.home) == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
