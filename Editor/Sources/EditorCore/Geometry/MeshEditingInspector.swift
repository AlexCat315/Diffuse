import CoveUIRuntime
import Foundation
import SIMDCompat

extension EditorMeshEditing {
    public func inspectorSections(for id: UInt64) -> [EditorInspectorSection] {
        guard isEditing, !hasTopologyPreview, entityID == id else { return [] }
        var fields = [EditorInspectorField(id: "mesh-selection-count",label: L("Selected"),
            value: .readOnly("\(selection.count) \(L(mode.title))"))]
        if let center = selectionCenter {
            func axis(_ i: Int) -> Binding<Float> {
                Binding(get: { [weak self] in self?.selectionCenter?[i] ?? center[i] },set: { [weak self] value in
                    guard let self, var point = selectionCenter else { return }
                    point[i] = value
                    _ = moveSelectionCenter(to: point)
                })
            }
            fields.append(.init(id: "mesh-selection-center",label: L("Center"),value: .vector3(x: axis(0),y: axis(1),z: axis(2))))
        }
        fields.append(.init(id: "mesh-select-all",label: L("Selection"),value: .action(title: L("Select All"),isDestructive: false,action: { [weak self] in self?.selectAll() })))
        fields.append(.init(id: "mesh-select-none",label: L("Selection"),value: .action(title: L("Deselect"),isDestructive: false,action: { [weak self] in self?.select([]) })))
        if mode == .face, !selection.isEmpty {
            fields.append(.init(id: "mesh-extrude-direction",label: L("Direction"),value: .stringOptions(
                Binding(get: { [weak self] in self?.extrusionDirection.rawValue ?? "normal" },set: { [weak self] value in
                    if let direction = EditorMeshExtrusionDirection(rawValue: value) { self?.extrusionDirection = direction }
                }),options: EditorMeshExtrusionDirection.allCases.map { .init(value: $0.rawValue,label: $0 == .normal ? L("Normal") : $0.rawValue.uppercased()) })))
            fields.append(.init(id: "mesh-extrude-distance",label: L("Distance"),value: .constrainedNumber(
                Binding(get: { [weak self] in self?.extrusionDistance ?? 0.25 },set: { [weak self] in self?.extrusionDistance = $0 }),
                min: -1000,max: 1000,step: 0.05,showsStepper: true)))
            fields.append(.init(id: "mesh-extrude-region",label: L("Topology"),value: .action(title: L("Extrude Region"),isDestructive: false,action: { [weak self] in _ = self?.extrudeRegion() })))
        }
        var section = EditorInspectorSection(id: "mesh-edit-selection",title: L("Mesh Selection"),fields: fields)
        section.supportsMultiSelection = false
        return [section]
    }
}
