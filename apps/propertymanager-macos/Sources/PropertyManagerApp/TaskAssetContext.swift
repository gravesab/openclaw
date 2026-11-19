import Foundation

enum TaskAssetContext {
    static func includes(taskAssetId: UUID?, selectedAssetId: UUID?) -> Bool {
        guard let selectedAssetId else { return true }
        return taskAssetId == selectedAssetId
    }
}
