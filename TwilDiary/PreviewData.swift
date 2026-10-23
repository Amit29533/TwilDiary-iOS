import Foundation
import TwilDiaryCore

enum PreviewData {
    static var workspace: Workspace { SampleWorkspace.make() }
    static var card: WatchCard {
        try! JSONDecoder().decode(WatchCard.self, from: Data("""
        {"progress":{"watched":2,"total":4},"season":{"number":1,"name":"Season 1","metadataLoadedAt":"2026-10-23T00:00:00Z"},"next":{"id":"ep-3","number":3},"previous":{"id":"watch-2","version":1,"episodeId":"ep-2","number":2}}
        """.utf8))
    }
}
