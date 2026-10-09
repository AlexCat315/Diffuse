import GuavaUIRuntime

public enum DataTableSelectionMode: Sendable { case single, multiple }
public struct DataTableSelection<ID: Hashable & Sendable>: Equatable, Sendable {
    public var selectedIDs: Set<ID> = []
    public var focusedID: ID?
    public var anchorID: ID?
    public var focusedColumnID: String?
    public init() {}
    public mutating func select<Record>(index: Int, in model: DataTableModel<Record, ID>, mode: DataTableSelectionMode,
                                        modifiers: KeyModifiers = []) {
        guard index >= 0 && index < model.count else { return }
        let id = model.rowID(at: index)
        if mode == .multiple, modifiers.contains(.shift), let anchorID, let anchor = model.index(for: anchorID) {
            selectedIDs = Set((min(anchor, index)...max(anchor, index)).map { model.rowID(at: $0) })
        } else if mode == .multiple, !modifiers.isDisjoint(with: [.gui, .ctrl]) {
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
            anchorID = id
        } else { selectedIDs = [id]; anchorID = id }
        focusedID = id
    }
    public mutating func retainExisting<Record>(in model: DataTableModel<Record, ID>) {
        selectedIDs = selectedIDs.filter { model.index(for: $0) != nil }
        if let focusedID, model.index(for: focusedID) == nil { self.focusedID = nil }
        if let anchorID, model.index(for: anchorID) == nil { self.anchorID = nil }
    }
}
