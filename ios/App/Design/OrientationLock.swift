import UIKit

/// The app stays upright; JellySpace's player turns sideways while it's open. The Info.plist allows
/// landscape, and this mask (asked by the app delegate) narrows it to what's on screen.
@MainActor enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func set(_ mask: UIInterfaceOrientationMask, turnTo orientation: UIInterfaceOrientationMask) {
        self.mask = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
    }
}

/// Only answers which orientations the app allows right now (OrientationLock).
final class TwilDiaryAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
