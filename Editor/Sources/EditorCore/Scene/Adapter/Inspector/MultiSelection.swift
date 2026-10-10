import Foundation
import GuavaUIRuntime
import SceneRuntime

extension EditorSceneAdapter {
    /// Intersects the schema by section, field and value type. Bindings retain
    /// each entity's own values, so editing one vector axis preserves the others.
    public func inspectorSections(for rawIDs: Set<UInt64>, primaryID: UInt64? = nil) -> [EditorInspectorSection] {
        var ids = rawIDs.sorted()
        if let primaryID, let index = ids.firstIndex(of: primaryID) {
            ids.remove(at: index)
            ids.insert(primaryID, at: 0)
        }
        guard !ids.isEmpty, ids.allSatisfy({ entitySummary(id: $0) != nil }) else { return [] }
        if ids.count == 1 { return inspectorSections(for: ids[0]) }
        let schemas = ids.map { inspectorSections(for: $0) }
        return schemas[0].compactMap { section in
            guard !["physics-settings", "particle-scalability"].contains(section.id) else { return nil }
            let matches = schemas.compactMap { $0.first { $0.id == section.id } }
            guard matches.count == ids.count else { return nil }
            let fields = section.fields.compactMap { field -> EditorInspectorField? in
                let values = matches.compactMap { $0.fields.first { $0.id == field.id }?.value }
                guard values.count == ids.count else { return nil }
                let batch = InspectorFieldBatch(scene: self, ids: rawIDs, values: values,
                                                sectionID: section.id, fieldID: field.id)
                guard let value = batch.value() else { return nil }
                return EditorInspectorField(id: field.id, label: field.label, value: value,
                                            presentation: field.presentation,
                                            isMixed: batch.isMixed, mixedAxes: batch.mixedAxes,
                                            applyPrimaryValue: batch.canApplyPrimary(value)
                                                ? { batch.applyPrimaryValue() } : nil, group: field.group)
            }
            guard !fields.isEmpty else { return nil }
            let groups = section.groups.filter { group in
                let identifiers = matches.compactMap { match -> String? in
                    guard case let .stringOptions(binding, _)? = match.fields.first(where: { $0.id == group.selectorFieldID })?.value else { return nil }
                    return binding.wrappedValue
                }
                return identifiers.count == ids.count && Set(identifiers).count == 1
            }
            let scriptLayout = section.componentTypeID.map { inspectorRenderers.layout(forComponentTypeID: $0) }
            if scriptLayout == .scriptBindings, !section.groups.isEmpty, groups.isEmpty {
                var result = section
                result.fields = [
                    EditorInspectorField(id: "script-mixed", label: L("Scripts"), value: .readOnly(L("Different script behaviors")))
                ]
                result.groups = []
                return result
            }
            var result = section
            result.fields = fields
            result.groups = groups
            return result
        }
    }
}

private final class InspectorFieldBatch {
    let scene: EditorSceneAdapter
    let ids: Set<UInt64>
    let values: [EditorInspectorFieldValue]
    let sectionID: String
    let fieldID: String
    var isMixed = false
    var mixedAxes: Set<String> = []
    private var primaryValueSetters: [() -> Void] = []

    init(scene: EditorSceneAdapter, ids: Set<UInt64>, values: [EditorInspectorFieldValue],
         sectionID: String, fieldID: String) {
        self.scene = scene; self.ids = ids; self.values = values
        self.sectionID = sectionID; self.fieldID = fieldID
    }

    private func merge<T: Equatable>(_ extract: (EditorInspectorFieldValue) -> Binding<T>?,
                                     axis: String? = nil) -> Binding<T>? {
        let bindings = values.compactMap(extract)
        guard bindings.count == values.count, let first = bindings.first else { return nil }
        if bindings.contains(where: { $0.wrappedValue != first.wrappedValue }) {
            isMixed = true
            if let axis { mixedAxes.insert(axis) }
        }
        primaryValueSetters.append {
            let next = first.wrappedValue
            for binding in bindings { binding.wrappedValue = next }
        }
        return Binding(get: { first.wrappedValue }, set: { [self] next in
            commit {
                for binding in bindings { binding.wrappedValue = next }
            }
        })
    }

    private func commit(_ edit: () -> Void) {
        // Validate the whole selection again at commit time.
        guard scene.isAuthoringEnabled,
              ids.allSatisfy({ scene.entitySummary(id: $0) != nil && !scene.isEntityLocked($0) }),
              ids.allSatisfy({ id in
                  scene.inspectorSections(for: id).first { $0.id == sectionID }?
                      .fields.contains { $0.id == fieldID } == true
              }) else { return }
        scene.withEditHistoryGroup(edit)
    }

    func canApplyPrimary(_ value: EditorInspectorFieldValue) -> Bool {
        guard isMixed, !primaryValueSetters.isEmpty else { return false }
        switch value {
        case let .stringOptions(binding, options): return options.contains { $0.value == binding.wrappedValue }
        case let .entityReference(binding, options): return binding.wrappedValue == 0 || options.contains { $0.id == binding.wrappedValue }
        case let .asset(binding, kinds, _): return binding.wrappedValue.map { kinds.isEmpty || kinds.contains($0.kind) } ?? true
        default: return true
        }
    }

    func applyPrimaryValue() {
        commit { for setter in primaryValueSetters { setter() } }
    }

    func value() -> EditorInspectorFieldValue? {
        switch values[0] {
        case let .readOnly(first):
            guard values.allSatisfy({ if case .readOnly = $0 { return true }; return false }) else { return nil }
            isMixed = values.contains { if case .readOnly(let text) = $0 { return text != first }; return false }
            return .readOnly(isMixed ? L("Mixed value") : first)
        case .action:
            // Actions can delete/reorder attachments; they need their own batch
            // policy. Component actions already provide that separate workflow.
            return nil
        case .text:
            guard let binding: Binding<String> = merge({ if case .text(let b) = $0 { return b }; return nil }) else { return nil }
            return .text(binding)
        case .bool:
            guard let binding: Binding<Bool> = merge({ if case .bool(let b) = $0 { return b }; return nil }) else { return nil }
            return .bool(binding)
        case .number:
            guard let binding: Binding<Float> = merge({ if case .number(let b) = $0 { return b }; return nil }) else { return nil }
            return .number(binding)
        case .color:
            guard let binding: Binding<Color> = merge({ if case .color(let b) = $0 { return b }; return nil }) else { return nil }
            return .color(binding)
        case .colliderShapeInstances:
            guard let binding: Binding<[ColliderShapeInstance]> = merge({ if case .colliderShapeInstances(let b) = $0 { return b }; return nil }) else { return nil }
            return .colliderShapeInstances(binding)
        case .particleCurve:
            guard let binding: Binding<ParticleCurve> = merge({ if case .particleCurve(let b) = $0 { return b }; return nil }) else { return nil }
            return .particleCurve(binding)
        case .particleSubEmitters:
            guard let binding: Binding<[ParticleSubEmitter]> = merge({ if case .particleSubEmitters(let b) = $0 { return b }; return nil }) else { return nil }
            return .particleSubEmitters(binding)
        case .particleModuleStack:
            guard let binding: Binding<ParticleModuleStack> = merge({ if case .particleModuleStack(let b) = $0 { return b }; return nil }) else { return nil }
            return .particleModuleStack(binding)
        case let .constrainedNumber(_, _, _, step, showsStepper):
            guard let binding: Binding<Float> = merge({
                if case .constrainedNumber(let b, _, _, _, _) = $0 { return b }; return nil
            }) else { return nil }
            let lower = values.compactMap { value -> Float? in
                if case .constrainedNumber(_, let min, _, _, _) = value { return min }; return nil
            }.max()
            let upper = values.compactMap { value -> Float? in
                if case .constrainedNumber(_, _, let max, _, _) = value { return max }; return nil
            }.min()
            if let lower, let upper, lower > upper { return nil }
            return .constrainedNumber(binding, min: lower, max: upper, step: step, showsStepper: showsStepper)
        case .vector3:
            guard let x: Binding<Float> = merge({ if case .vector3(let b, _, _) = $0 { return b }; return nil }, axis: "x"),
                  let y: Binding<Float> = merge({ if case .vector3(_, let b, _) = $0 { return b }; return nil }, axis: "y"),
                  let z: Binding<Float> = merge({ if case .vector3(_, _, let b) = $0 { return b }; return nil }, axis: "z")
            else { return nil }
            return .vector3(x: x, y: y, z: z)
        case let .stringOptions(_, options):
            guard let binding: Binding<String> = merge({ if case .stringOptions(let b, _) = $0 { return b }; return nil }) else { return nil }
            let common = options.filter { option in values.allSatisfy {
                if case .stringOptions(_, let choices) = $0 { return choices.contains(option) }; return false
            }}
            return .stringOptions(binding, options: common)
        case let .entityReference(_, options):
            guard let binding: Binding<UInt64> = merge({ if case .entityReference(let b, _) = $0 { return b }; return nil }) else { return nil }
            let common = options.filter { option in values.allSatisfy {
                if case .entityReference(_, let choices) = $0 { return choices.contains(option) }; return false
            }}
            return .entityReference(binding, options: common)
        case let .json(_, minHeight):
            guard let binding: Binding<String> = merge({ if case .json(let b, _) = $0 { return b }; return nil }) else { return nil }
            return .json(binding, minHeight: minHeight)
        case let .asset(_, _, placeholder):
            guard let binding: Binding<EditorInspectorAssetRef?> = merge({ if case .asset(let b, _, _) = $0 { return b }; return nil }) else { return nil }
            let restrictions = values.compactMap { value -> Set<String>? in
                if case .asset(_, let kinds, _) = value, !kinds.isEmpty { return kinds }; return nil
            }
            let kinds = restrictions.dropFirst().reduce(restrictions.first ?? []) { $0.intersection($1) }
            guard restrictions.isEmpty || !kinds.isEmpty else { return nil }
            return .asset(binding, acceptedKinds: kinds, placeholder: placeholder)
        }
    }
}
