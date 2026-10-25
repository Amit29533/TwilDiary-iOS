import Foundation
import TwilDiaryCore

extension DiaryStore {
    func createManualTitle(_ input: ManualTitleInput) async throws -> String {
        guard !busy, canMutate else { throw APIError.message("Wait for the current change before adding a title.") }
        let revision = sessionRevision
        busy = true; defer { if revision == sessionRevision { busy = false } }
        var confirmed = false
        do {
            let encoded = try JSONEncoder().encode(input)
            guard let body = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw APIError.message("The title could not be prepared. Try again.") }
            let receipt: ManualTitleReceipt = try await read("/api/titles", method: "POST", body: body)
            guard receipt.title.id == input.id else { throw APIError.message("The saved title identity did not match. Refresh before trying again.") }
            confirmed = true; try await reload(); return receipt.title.id
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard revision == sessionRevision else { throw CancellationError() }
            if confirmed { throw APIError.message("Added to your library, but the refresh failed. Try again with the same title to reopen it; a second copy will not be created.") }
            throw error
        }
    }
    private struct ManualTitleReceipt: Decodable {
        struct Identity: Decodable { let id: String }
        let title: Identity
    }
}
