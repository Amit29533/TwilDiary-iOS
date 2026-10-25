import Foundation
import TwilDiaryCore

extension DiaryStore {
    func unmatchedScans(after: String? = nil) async throws -> ScannerReviewPage {
        if isPreview && !canMutate { return ScannerReviewPage(items: [], nextCursor: nil) }
        return try await read(CatalogTools.apiPath("/api/scanner/review", query: ["after": after ?? ""]))
    }
    @discardableResult func resolveScan(_ scan: UnmatchedScan, titleID: String) async -> Bool {
        await perform {
            struct Receipt: Decodable { let resolved: Bool, titleId: String }
            let result: Receipt = try await self.read("/api/scanner/review/\(scan.id)/resolve", method: "POST", body: ["titleId": titleID, "expectedVersion": scan.version])
            guard result.resolved, result.titleId == titleID else { throw APIError.message("The folder match was not confirmed. Refresh before retrying.") }
        }
    }
}
