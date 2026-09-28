import EngineKernel

struct AssetBrowserSelectionModel: Equatable {
    private(set) var selectedIDs: Set<String> = []
    private(set) var anchorID: String?

    mutating func select(_ assetID: String,
                         in orderedVisibleIDs: [String],
                         modifiers: KeyModifiers = []) {
        guard let clickedIndex = orderedVisibleIDs.firstIndex(of: assetID) else { return }
        selectedIDs.formIntersection(orderedVisibleIDs)

        if modifiers.hasShift,
           let anchorID,
           let anchorIndex = orderedVisibleIDs.firstIndex(of: anchorID) {
            let lower = min(anchorIndex, clickedIndex)
            let upper = max(anchorIndex, clickedIndex)
            let range = Set(orderedVisibleIDs[lower...upper])
            if modifiers.hasCtrl || modifiers.hasGui {
                selectedIDs.formUnion(range)
            } else {
                selectedIDs = range
            }
            return
        }

        if modifiers.hasCtrl || modifiers.hasGui {
            if !selectedIDs.insert(assetID).inserted {
                selectedIDs.remove(assetID)
            }
        } else {
            selectedIDs = [assetID]
        }
        anchorID = assetID
    }

    mutating func selectAll(in orderedVisibleIDs: [String]) {
        selectedIDs = Set(orderedVisibleIDs)
        anchorID = orderedVisibleIDs.first
    }

    mutating func clear() {
        selectedIDs.removeAll()
        anchorID = nil
    }

    static func adjacentAssetID(from assetID: String?,
                                in orderedVisibleIDs: [String],
                                direction: Int) -> String? {
        guard !orderedVisibleIDs.isEmpty, direction != 0 else { return nil }
        let currentIndex = assetID.flatMap(orderedVisibleIDs.firstIndex(of:))
            ?? (direction > 0 ? -1 : orderedVisibleIDs.count)
        let nextIndex = currentIndex + (direction > 0 ? 1 : -1)
        guard orderedVisibleIDs.indices.contains(nextIndex) else { return nil }
        return orderedVisibleIDs[nextIndex]
    }
}
