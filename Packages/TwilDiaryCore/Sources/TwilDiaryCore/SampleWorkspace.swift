import Foundation

/// Synthetic data for previews and simulator tests. Never a fallback for a failed API request.
public enum SampleWorkspace {
    public static func make() -> Workspace {
        let url = Bundle.module.url(forResource: "workspace", withExtension: "json")!
        return try! JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
    }
}
