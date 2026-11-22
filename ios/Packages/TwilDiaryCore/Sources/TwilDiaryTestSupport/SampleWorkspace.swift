import Foundation
import TwilDiaryCore

/// Synthetic data linked only by test targets, never by the shipping application.
public enum SampleWorkspace {
    public static func make() -> Workspace {
        let url = Bundle.module.url(forResource: "workspace", withExtension: "json")!
        return try! JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
    }
    /// Explicitly mapped fixtures for transport tests; UI fixtures intentionally remain unmapped.
    public static func mapped() throws -> Workspace {
        let data = try JSONEncoder().encode(make())
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var titles = object["titles"] as! [[String: Any]]
        for index in titles.indices { titles[index]["tmdbId"] = 1000 + index }
        object["titles"] = titles
        return try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    }

}
