import Foundation
import TwilDiaryCore

/// Synthetic data linked only by test targets, never by the shipping application.
public enum SampleWorkspace {
    public static func make() -> Workspace {
        let url = Bundle.module.url(forResource: "workspace", withExtension: "json")!
        return try! JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
    }
}
