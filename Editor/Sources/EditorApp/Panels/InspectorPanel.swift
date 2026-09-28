#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime

struct InspectorPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    private let sessionState: InspectorPanelSessionState
    @State private var searchText: String

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
        let sessionState = InspectorPanelSessionRegistry.state(for: store)
        self.sessionState = sessionState
        _searchText = State(wrappedValue: sessionState.searchText)
    }

    var body: some View {
        StoreScope(store) { store in
            let _ = store.sceneRevision
            let _ = store.uiRefreshRevision
            let selectedEntityID = store.selectedEntityID
            let selectedEntityIDs = store.selectedEntityIDs
            let entity = scene.entitySummary(id: selectedEntityID)
            let sections = scene.inspectorSections(for: selectedEntityID)
            let collapsedIDs = store.inspectorCollapsedSectionIDs
            let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let filteredSections = InspectorSectionFilter.filter(sections, query: trimmedSearchText)
            let totalFieldCount = sections.reduce(0) { $0 + $1.fields.count }
            let visibleFieldCount = filteredSections.reduce(0) { $0 + $1.fields.count }
            let isAuthoringEnabled = EditorSceneAuthoringPolicy.canEditScene(
                during: store.playbackState
            )
            let canEditSelection = isAuthoringEnabled
                && selectedEntityIDs.count == 1
                && selectedEntityID.map { !scene.isEntityLocked($0) } == true
            let searchBinding = Binding<String>(
                get: { searchText },
                set: updateSearchText
            )

            Box(direction: .column, alignItems: .stretch) {
                if let entity {
                    InspectorSelectionSummary(entity: entity,
                                              componentCount: scene.componentKinds(on: entity.id).count,
                                              selectionCount: selectedEntityIDs.count,
                                              isLocked: scene.isEntityLocked(entity.id),
                                              isAuthoringEnabled: isAuthoringEnabled)

                    ComponentActionsBar(store: store,
                                        scene: scene,
                                        entityIDs: selectedEntityIDs.isEmpty
                                            ? [entity.id]
                                            : selectedEntityIDs,
                                        isAuthoringEnabled: isAuthoringEnabled)

                    Divider()

                    EditorPanelSearchBar(
                        L("Search Properties"),
                        text: searchBinding,
                        summary: trimmedSearchText.isEmpty
                            ? "\(totalFieldCount)"
                            : "\(visibleFieldCount) / \(totalFieldCount)",
                        onCancel: { updateSearchText("") }
                    ) {
                        EditorPanelIconButton(UICommonIcons.chevronDown,
                                              tooltip: L("Expand All"),
                                              isEnabled: trimmedSearchText.isEmpty) {
                            setSections(sections, collapsed: false)
                        }
                        EditorPanelIconButton(UICommonIcons.chevronRight,
                                              tooltip: L("Collapse All"),
                                              isEnabled: trimmedSearchText.isEmpty) {
                            setSections(sections, collapsed: true)
                        }
                    }

                    Divider()

                    if filteredSections.isEmpty {
                        EditorPanelEmptyState(
                            L("No matching properties"),
                            detail: trimmedSearchText.isEmpty ? nil : "\"\(trimmedSearchText)\""
                        )
                        .flex()
                    } else {
                        PropertyGrid(propertySections(filteredSections,
                                                      collapsedIDs: trimmedSearchText.isEmpty
                                                        ? collapsedIDs
                                                        : [],
                                                      entityID: selectedEntityID,
                                                      isEditable: canEditSelection),
                                     labelWidth: 108,
                                     minValueWidth: 132,
                                     rowHeight: 26,
                                     rowSpacing: 1,
                                     sectionSpacing: 6,
                                     contentPadding: 6,
                                     scrollAxes: .vertical,
                                     emptyText: L("No properties"),
                                     onSectionCollapseChanged: { id, isCollapsed in
                            store.dispatch(.setInspectorSectionCollapsed(id: id, isCollapsed: isCollapsed))
                        })
                            .flex()
                    }
                } else {
                    EditorPanelEmptyState(
                        L("No selection"),
                        detail: L("Select an entity in Hierarchy to inspect SceneRuntime components.")
                    )
                    .flex()
                }
            }
            .frame(minWidth: 300)
        }
    }

    private func updateSearchText(_ value: String) {
        sessionState.searchText = value
        searchText = value
    }

    private func setSections(_ sections: [EditorInspectorSection], collapsed: Bool) {
        store.dispatch(.setInspectorSectionsCollapsed(
            ids: Set(sections.map(\.id)),
            isCollapsed: collapsed
        ))
    }

    private struct InspectorSelectionSummary: View {
        let entity: EditorSceneEntitySummary
        let componentCount: Int
        let selectionCount: Int
        let isLocked: Bool
        let isAuthoringEnabled: Bool

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 6) {
                Row(alignment: .center, spacing: 8) {
                    Box(direction: .column, alignItems: .stretch, spacing: 2) {
                        Text(entity.name)
                            .lineLimit(1)
                            .font(.bodyStrong)
                            .foregroundColor(.onSurface)

                        Text(entity.kind)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                    }
                    .flex()
                    EditorPanelBadge("ID \(entity.id)")
                }

                Row(alignment: .center, spacing: 6) {
                    Text(L("Components"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                    Text("\(componentCount)")
                        .font(.mono)
                        .foregroundColor(.onSurface)
                        .padding(horizontal: 6, vertical: 1)
                        .background(.surfaceVariant)
                        .cornerRadius(3)
                    if selectionCount > 1 {
                        EditorPanelBadge("\(selectionCount) \(L("selected"))",
                                         foreground: .accent)
                    }
                    if isLocked {
                        EditorPanelBadge(L("Locked"), foreground: .warning)
                    } else if !isAuthoringEnabled {
                        EditorPanelBadge(L("Read Only"), foreground: .warning)
                    }
                    Spacer(minLength: 0)
                }

                if selectionCount > 1 {
                    Text(L("Properties show the primary selection read-only; component actions apply to all selected entities."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .padding(horizontal: 9, vertical: 8)
            .background(.surface)
        }
    }

    private struct InspectorReadOnlyValue: View {
        let text: String

        var body: some View {
            Row(alignment: .center, spacing: 0) {
                Text(text)
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(.onSurfaceVariant)
                    .flex()
            }
            .padding(horizontal: 8, vertical: 5)
            .background(.surfaceSunken)
            .cornerRadius(7)
            .border(.border, width: 1)
            .clipped()
        }
    }


    private struct InspectorBooleanValue: View {
        let binding: Binding<Bool>

        var body: some View {
            Row(alignment: .center, spacing: 6) {
                Checkbox(isOn: binding)
                Text(binding.wrappedValue ? L("On") : L("Off"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)
                    .flex()
            }
        }
    }

    private struct InspectorNumberValue: View {
        let binding: Binding<Float>
        let minValue: Float?
        let maxValue: Float?
        let step: Float?
        let showsStepper: Bool

        var body: some View {
            NumberField(value: binding,
                        decimals: 2,
                        size: .small,
                        minValue: minValue,
                        maxValue: maxValue,
                        step: step,
                        showsStepper: showsStepper)
                .frame(minWidth: 96)
                .flex()
        }
    }

    private struct InspectorTextValue: View {
        let identity: String
        let binding: Binding<String>

        var body: some View {
            // Draft-while-editing: model normalization (empty entity name →
            // fallback, clip lookups) must not rewrite the text mid-edit.
            CommitOnBlurTextField(identity: identity, text: binding, size: .small)
                .flex()
                .clipped()
        }
    }

    private struct InspectorStringOptionsValue: View {
        let binding: Binding<String>
        let options: [EditorInspectorStringOption]
        @State private var isPresented: Bool = false

        var body: some View {
            Popover(isPresented: $isPresented, width: 230) {
                Row(alignment: .center, spacing: 5) {
                    Text(selectedLabel, lineLimit: 1)
                        .font(.caption)
                        .foregroundColor(.onSurface)
                        .flex()
                    Icon(UICommonIcons.chevronDown, size: 8, color: .onSurfaceMuted)
                }
                .padding(horizontal: 8, vertical: 4)
                .background(.surfaceSunken)
                .cornerRadius(3)
            } content: {
                Menu(options.map { option in
                    .item(MenuItem(id: "string-option-\(option.value)",
                                   title: option.label,
                                   isSelected: option.value == binding.wrappedValue,
                                   action: { binding.wrappedValue = option.value }))
                }, width: 230, maxVisibleRows: 12, onItemActivated: {
                    isPresented = false
                })
            }
        }

        private var selectedLabel: String {
            options.first(where: { $0.value == binding.wrappedValue })?.label
                ?? "\(L("Missing")): \(binding.wrappedValue)"
        }
    }

    private struct InspectorActionValue: View {
        let title: String
        let isDestructive: Bool
        let action: () -> Void

        var body: some View {
            if isDestructive {
                Button(title, role: .destructive, action: action)
                    .buttonStyle(.destructive)
            } else {
                Button(title, action: action)
                    .buttonStyle(.secondary)
            }
        }
    }

    private struct InspectorVectorValue: View {
        let x: Binding<Float>
        let y: Binding<Float>
        let z: Binding<Float>

        var body: some View {
            Vec3Field(x: x, y: y, z: z, decimals: 2, size: .small)
                .flex(1, shrink: 1, basis: 0)
                .clipped()
        }
    }

    private struct InspectorColorValue: View {
        let binding: Binding<Color>

        var body: some View {
            ColorField(color: binding,
                       showAlpha: false,
                       showsInlineValues: true)
                .flex()
                .clipped()
        }
    }

    private struct InspectorLightTypeValue: View {
        let binding: Binding<LightType>

        var body: some View {
            EnumField(value: binding, width: 150) { type in
                switch type {
                case .directional: return L("Directional")
                case .point: return L("Point")
                case .spot: return L("Spot")
                }
            }
        }
    }

    private struct InspectorRigidBodyMotionValue: View {
        let binding: Binding<RigidBodyMotionType>

        var body: some View {
            EnumField(value: binding, width: 150) { type in
                switch type {
                case .static: return L("Static")
                case .dynamic: return L("Dynamic")
                case .kinematic: return L("Kinematic")
                }
            }
        }
    }

    private struct InspectorPhysicsSimulationModeValue: View {
        let binding: Binding<PhysicsSimulationMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .off: return L("Off")
                case .preview: return L("Preview")
                case .play: return L("Play")
                case .bake: return L("Bake")
                }
            }
        }
    }

    private struct InspectorVehicleControllerKindValue: View {
        let binding: Binding<VehicleControllerKind>

        var body: some View {
            EnumField(value: binding, width: 150) { kind in
                switch kind {
                case .wheeled: return L("Wheeled")
                case .tracked: return L("Tracked")
                case .motorcycle: return L("Motorcycle")
                }
            }
        }
    }

    private struct InspectorColliderShapeKindValue: View {
        let binding: Binding<ColliderShapeKind>

        var body: some View {
            EnumField(value: binding, width: 150) { kind in
                switch kind {
                case .box: return L("Box")
                case .sphere: return L("Sphere")
                case .capsule: return L("Capsule")
                case .cylinder: return L("Cylinder")
                case .heightField: return L("Height Field")
                case .mesh: return L("Mesh")
                case .convex: return L("Convex")
                }
            }
        }
    }

    private struct InspectorPhysicsJointKindValue: View {
        let binding: Binding<PhysicsJointKind>

        var body: some View {
            EnumField(value: binding, width: 150) { kind in
                switch kind {
                case .pointToPoint: return L("Point")
                case .fixed: return L("Fixed")
                case .distance: return L("Distance")
                case .hinge: return L("Hinge")
                case .slider: return L("Slider")
                case .cone: return L("Cone / Swing Twist")
                case .sixDOF: return L("Six DOF")
                }
            }
        }
    }

    private struct InspectorPhysicsJointMotorModeValue: View {
        let binding: Binding<PhysicsJointMotorMode>

        var body: some View {
            EnumField(value: binding, width: 150) { mode in
                switch mode {
                case .disabled: return L("Disabled")
                case .position: return L("Position")
                case .velocity: return L("Velocity")
                }
            }
        }
    }

    private struct InspectorEntityReferenceValue: View {
        let binding: Binding<UInt64>
        let options: [EditorInspectorEntityOption]
        @State private var isPresented: Bool = false

        var body: some View {
            Popover(isPresented: $isPresented, width: 220) {
                Row(alignment: .center, spacing: 5) {
                    Text(selectedLabel, lineLimit: 1)
                        .font(.caption)
                        .foregroundColor(.onSurface)
                        .flex()
                    Icon(UICommonIcons.chevronDown, size: 8, color: .onSurfaceMuted)
                }
                .padding(horizontal: 8, vertical: 4)
                .background(.surfaceSunken)
                .cornerRadius(3)
            } content: {
                Menu(options.map { option in
                    .item(MenuItem(
                        id: "entity-reference-\(option.id)",
                        title: "\(option.name) · \(option.id)",
                        isSelected: option.id == binding.wrappedValue,
                        action: { binding.wrappedValue = option.id }
                    ))
                }, width: 220, maxVisibleRows: 10, onItemActivated: {
                    isPresented = false
                })
            }
        }

        private var selectedLabel: String {
            guard let selected = options.first(where: { $0.id == binding.wrappedValue }) else {
                return "\(L("Missing Entity")) · \(binding.wrappedValue)"
            }
            return "\(selected.name) · \(selected.id)"
        }
    }



    private func propertySections(_ sections: [EditorInspectorSection],
                                  collapsedIDs: Set<String>,
                                  entityID: UInt64?,
                                  isEditable: Bool) -> [PropertyGridSection] {
        func row(for field: EditorInspectorField, sectionID: String) -> PropertyGridRow {
            PropertyGridRow(id: field.id,
                            label: field.label,
                            rowHeight: field.value.preferredRowHeight(defaultHeight: 28),
                            layout: field.value.preferredRowLayout) {
                if isEditable {
                    fieldView(field.value,
                              identity: "\(entityID.map(String.init) ?? "none")/\(sectionID)/\(field.id)")
                } else {
                    InspectorReadOnlyValue(text: field.value.readOnlyDescription)
                }
            }
        }

        return sections.flatMap { section -> [PropertyGridSection] in
            let startsCollapsed = collapsedIDs.contains(section.id)
            if section.id == "particle-emitter" {
                return InspectorParticlePropertyLayout.sections(
                    for: section,
                    collapsedIDs: collapsedIDs,
                    parentStartsCollapsed: startsCollapsed,
                    rowBuilder: row
                )
            }

            return [
                PropertyGridSection(
                    id: section.id,
                    title: section.title,
                    rows: section.fields.map { row(for: $0, sectionID: section.id) },
                    isCollapsible: true,
                    startsCollapsed: startsCollapsed
                )
            ]
        }
    }

    private func fieldView(_ value: EditorInspectorFieldValue,
                           identity: String) -> some View {
        switch value {
        case let .readOnly(text):
            return AnyView(InspectorReadOnlyValue(text: text))
        case let .text(binding):
            return AnyView(InspectorTextValue(identity: identity, binding: binding))
        case let .stringOptions(binding, options):
            return AnyView(InspectorStringOptionsValue(binding: binding, options: options))
        case let .action(title, isDestructive, action):
            return AnyView(InspectorActionValue(title: title,
                                                isDestructive: isDestructive,
                                                action: action))
        case let .bool(binding):
            return AnyView(InspectorBooleanValue(binding: binding))
        case let .number(binding):
            return AnyView(InspectorNumberValue(binding: binding,
                                                minValue: nil,
                                                maxValue: nil,
                                                step: nil,
                                                showsStepper: false))
        case let .constrainedNumber(binding, min, max, step, showsStepper):
            return AnyView(InspectorNumberValue(binding: binding,
                                                minValue: min,
                                                maxValue: max,
                                                step: step,
                                                showsStepper: showsStepper))
        case let .vector3(x, y, z):
            return AnyView(InspectorVectorValue(x: x, y: y, z: z))
        case let .color(binding):
            return AnyView(InspectorColorValue(binding: binding))
        case let .json(binding, minHeight):
            return AnyView(JsonField(text: binding, minHeight: minHeight))
        case let .lightType(binding):
            return AnyView(InspectorLightTypeValue(binding: binding))
        case let .physicsSimulationMode(binding):
            return AnyView(InspectorPhysicsSimulationModeValue(binding: binding))
        case let .vehicleControllerKind(binding):
            return AnyView(InspectorVehicleControllerKindValue(binding: binding))
        case let .rigidBodyMotion(binding):
            return AnyView(InspectorRigidBodyMotionValue(binding: binding))
        case let .colliderShapeKind(binding):
            return AnyView(InspectorColliderShapeKindValue(binding: binding))
        case let .colliderShapeInstances(binding):
            return AnyView(InspectorColliderShapeInstancesValue(binding: binding))
        case let .entityReference(binding, options):
            return AnyView(InspectorEntityReferenceValue(binding: binding, options: options))
        case let .physicsJointKind(binding):
            return AnyView(InspectorPhysicsJointKindValue(binding: binding))
        case let .physicsJointMotorMode(binding):
            return AnyView(InspectorPhysicsJointMotorModeValue(binding: binding))
        case let .particleEmissionShape(binding):
            return AnyView(InspectorParticleEmissionShapeValue(binding: binding))
        case let .particleCollisionMode(binding):
            return AnyView(InspectorParticleCollisionModeValue(binding: binding))
        case let .particleSimulationSpace(binding):
            return AnyView(InspectorParticleSimulationSpaceValue(binding: binding))
        case let .particleSimulationBackend(binding):
            return AnyView(InspectorParticleSimulationBackendValue(binding: binding))
        case let .particleCurve(binding):
            return AnyView(InspectorParticleCurveValue(binding: binding))
        case let .particleBlendMode(binding):
            return AnyView(InspectorParticleBlendModeValue(binding: binding))
        case let .particleRenderMode(binding):
            return AnyView(InspectorParticleRenderModeValue(binding: binding))
        case let .particleSortMode(binding):
            return AnyView(InspectorParticleSortModeValue(binding: binding))
        case let .particleTextureSheetPlaybackMode(binding):
            return AnyView(InspectorParticleTextureSheetPlaybackModeValue(binding: binding))
        case let .particleRenderAlignment(binding):
            return AnyView(InspectorParticleRenderAlignmentValue(binding: binding))
        case let .particleRenderBoundsMode(binding):
            return AnyView(InspectorParticleRenderBoundsModeValue(binding: binding))
        case let .particleForceMode(binding):
            return AnyView(InspectorParticleForceModeValue(binding: binding))
        case let .particleVectorFieldMode(binding):
            return AnyView(InspectorParticleVectorFieldModeValue(binding: binding))
        case let .particleSubEmitterTrigger(binding):
            return AnyView(InspectorParticleSubEmitterTriggerValue(binding: binding))
        case let .particleSubEmitters(binding):
            return AnyView(InspectorParticleSubEmittersValue(binding: binding))
        case let .particleModuleStack(binding):
            return AnyView(InspectorParticleModuleStackValue(binding: binding))
        case let .asset(binding, acceptedKinds, placeholder):
            return AnyView(AssetRefField(value: assetRefBinding(binding),
                                         activePayload: activeAssetDropPayload,
                                         acceptedKinds: acceptedKinds,
                                         pickerOptions: assetPickerOptions(acceptedKinds: acceptedKinds),
                                         placeholder: placeholder))
        }
    }

    private var activeAssetDropPayload: Binding<AssetDropPayload?> {
        Binding(
            get: { [store] in
                store.activeAssetDrag.map {
                    let asset = EditorAssetCatalog.asset(for: $0.assetID)
                    return AssetDropPayload(id: $0.assetID,
                                            name: $0.displayName,
                                            subtitle: asset?.relativePath,
                                            kind: $0.kindLabel,
                                            previewPath: asset?.previewPath)
                }
            },
            set: { _ in }
        )
    }

    private func assetRefBinding(_ binding: Binding<EditorInspectorAssetRef?>) -> Binding<AssetRef?> {
        Binding(
            get: {
                binding.wrappedValue.map {
                    AssetRef(id: $0.id,
                             name: $0.name,
                             subtitle: $0.subtitle,
                             kind: $0.kind,
                             previewPath: $0.previewPath)
                }
            },
            set: { next in
                binding.wrappedValue = next.map {
                    EditorInspectorAssetRef(id: $0.id,
                                            name: $0.name,
                                            subtitle: $0.subtitle,
                                            kind: $0.kind,
                                            previewPath: $0.previewPath)
                }
            }
        )
    }

    private func assetPickerOptions(acceptedKinds: Set<String>) -> [AssetRef] {
        InspectorAssetPickerCache.options(acceptedKinds: acceptedKinds)
    }
}

enum InspectorSectionFilter {
    static func filter(_ sections: [EditorInspectorSection], query: String) -> [EditorInspectorSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sections }

        return sections.compactMap { section in
            if section.title.range(of: needle, options: .caseInsensitive) != nil {
                return section
            }

            let fields = section.fields.filter {
                $0.label.range(of: needle, options: .caseInsensitive) != nil
                    || $0.value.readOnlyDescription.range(
                        of: needle,
                        options: .caseInsensitive
                    ) != nil
            }
            guard !fields.isEmpty else { return nil }
            return EditorInspectorSection(id: section.id,
                                          title: section.title,
                                          fields: fields)
        }
    }
}

/// Dock reconciliation can reconstruct the Inspector view after every scene
/// revision. Keep the user's active property query attached to the editor
/// session so editing a value or changing the primary selection does not erase
/// the investigation context.
private final class InspectorPanelSessionState {
    var searchText: String = ""
}

private enum InspectorPanelSessionRegistry {
    nonisolated(unsafe) private static var states: [
        ObjectIdentifier: InspectorPanelSessionState
    ] = [:]

    static func state(for store: EditorStore) -> InspectorPanelSessionState {
        let key = ObjectIdentifier(store)
        if let existing = states[key] {
            return existing
        }
        let created = InspectorPanelSessionState()
        states[key] = created
        return created
    }
}

private enum InspectorAssetPickerCache {
    nonisolated(unsafe) private static var cachedSignature: String = ""
    nonisolated(unsafe) private static var cachedOptions: [String: [AssetRef]] = [:]

    static func options(acceptedKinds: Set<String>) -> [AssetRef] {
        let entries = EditorAssetCatalog.entries()
        let signature = entries.map {
            "\($0.id)|\($0.kind.sceneKindLabel)|\($0.name)|\($0.relativePath)|\($0.absolutePath)"
        }.joined(separator: "\n")
        let key = acceptedKinds.sorted().joined(separator: "|")

        if signature == cachedSignature, let hit = cachedOptions[key] {
            return hit
        }
        if signature != cachedSignature {
            cachedOptions.removeAll(keepingCapacity: true)
            cachedSignature = signature
        }

        let options = entries
            .filter { acceptedKinds.isEmpty || acceptedKinds.contains($0.kind.sceneKindLabel) }
            .sorted { lhs, rhs in
                lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
            }
            .map {
                AssetRef(id: $0.id,
                         name: $0.name,
                         subtitle: $0.relativePath,
                         kind: $0.kind.sceneKindLabel,
                         previewPath: $0.previewPath)
            }
        cachedOptions[key] = options
        return options
    }
}

private extension EditorAsset {
    var previewPath: String? {
        kind.isTexture ? absolutePath : nil
    }
}

private extension EditorInspectorFieldValue {
    var readOnlyDescription: String {
        switch self {
        case let .readOnly(value): return value
        case let .text(binding): return binding.wrappedValue
        case let .stringOptions(binding, options):
            return options.first(where: { $0.value == binding.wrappedValue })?.label
                ?? binding.wrappedValue
        case let .action(title, _, _):
            return "\(title) · \(L("Unavailable while scene editing is disabled"))"
        case let .bool(binding): return binding.wrappedValue ? L("On") : L("Off")
        case let .number(binding), let .constrainedNumber(binding, _, _, _, _):
            return String(format: "%.3g", binding.wrappedValue)
        case let .vector3(x, y, z):
            return String(format: "%.3g, %.3g, %.3g",
                          x.wrappedValue, y.wrappedValue, z.wrappedValue)
        case let .color(binding):
            let value = binding.wrappedValue
            return String(format: "RGBA %.2f, %.2f, %.2f, %.2f",
                          value.r, value.g, value.b, value.a)
        case let .json(binding, _): return binding.wrappedValue
        case let .lightType(binding): return String(describing: binding.wrappedValue)
        case let .physicsSimulationMode(binding): return String(describing: binding.wrappedValue)
        case let .vehicleControllerKind(binding): return String(describing: binding.wrappedValue)
        case let .rigidBodyMotion(binding): return String(describing: binding.wrappedValue)
        case let .colliderShapeKind(binding): return String(describing: binding.wrappedValue)
        case let .colliderShapeInstances(binding): return "\(binding.wrappedValue.count)"
        case let .entityReference(binding, options):
            return options.first(where: { $0.id == binding.wrappedValue })?.name
                ?? String(binding.wrappedValue)
        case let .physicsJointKind(binding): return String(describing: binding.wrappedValue)
        case let .physicsJointMotorMode(binding): return String(describing: binding.wrappedValue)
        case let .particleEmissionShape(binding): return String(describing: binding.wrappedValue)
        case let .particleCollisionMode(binding): return String(describing: binding.wrappedValue)
        case let .particleSimulationSpace(binding): return String(describing: binding.wrappedValue)
        case let .particleSimulationBackend(binding): return String(describing: binding.wrappedValue)
        case let .particleCurve(binding): return String(describing: binding.wrappedValue)
        case let .particleBlendMode(binding): return String(describing: binding.wrappedValue)
        case let .particleRenderMode(binding): return String(describing: binding.wrappedValue)
        case let .particleSortMode(binding): return String(describing: binding.wrappedValue)
        case let .particleTextureSheetPlaybackMode(binding): return String(describing: binding.wrappedValue)
        case let .particleRenderAlignment(binding): return String(describing: binding.wrappedValue)
        case let .particleRenderBoundsMode(binding): return String(describing: binding.wrappedValue)
        case let .particleForceMode(binding): return String(describing: binding.wrappedValue)
        case let .particleVectorFieldMode(binding): return String(describing: binding.wrappedValue)
        case let .particleSubEmitterTrigger(binding): return String(describing: binding.wrappedValue)
        case let .particleSubEmitters(binding): return "\(binding.wrappedValue.count)"
        case let .particleModuleStack(binding): return "\(binding.wrappedValue.modules.count)"
        case let .asset(binding, _, placeholder):
            return binding.wrappedValue?.name ?? placeholder
        }
    }

    var preferredRowLayout: PropertyGridRowLayout {
        switch self {
        case .colliderShapeInstances, .particleCurve, .particleSubEmitters, .particleModuleStack:
            return .fullWidth
        default:
            return .twoColumn
        }
    }

    func preferredRowHeight(defaultHeight: Float) -> Float? {
        switch self {
        case .vector3:
            return max(defaultHeight, 30)
        case .asset:
            return max(defaultHeight, 34)
        case let .colliderShapeInstances(binding):
            return max(
                defaultHeight,
                ColliderShapeInstanceEditorLayout.rowHeight(shapeCount: binding.wrappedValue.count)
            )
        case let .particleCurve(binding):
            if case .keyframes(let keyframes) = binding.wrappedValue {
                return max(defaultHeight, ParticleCurveEditorLayout.rowHeight(keyframeCount: keyframes.count))
            }
            return max(defaultHeight, ParticleCurveEditorLayout.linearRowHeight)
        case let .particleSubEmitters(binding):
            return max(defaultHeight, ParticleSubEmitterEditorLayout.rowHeight(ruleCount: binding.wrappedValue.count))
        case let .particleModuleStack(binding):
            return max(defaultHeight,
                       ParticleModuleStackEditorLayout.rowHeight(stack: binding.wrappedValue))
        case let .json(_, minHeight):
            return max(defaultHeight, minHeight + 34)
        default:
            return nil
        }
    }
}


/// Inspector affordances for adding and removing optional SceneRuntime
/// components. Structural components such as name and transform stay outside
/// these menus so an entity cannot be left in an invalid editor state.
private struct ComponentActionsBar: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    let entityIDs: Set<UInt64>
    let isAuthoringEnabled: Bool
    @State private var isAddPresented: Bool = false
    @State private var isRemovePresented: Bool = false
    @State private var isResetPresented: Bool = false

    var body: some View {
        let addableKinds = scene.addableComponentKinds(on: entityIDs)
        let commonKinds = scene.commonComponentKinds(on: entityIDs)
        let containsLockedEntity = entityIDs.contains { scene.isEntityLocked($0) }
        let canMutate = isAuthoringEnabled && !containsLockedEntity && !entityIDs.isEmpty
        return Row(alignment: .center, spacing: 6) {
            if !isAuthoringEnabled {
                Text(L("Stop simulation to edit the scene"))
                    .font(.caption)
                    .foregroundColor(.warning)
                    .padding(horizontal: 4, vertical: 4)
            } else if containsLockedEntity {
                Text(L("Selection contains locked entities — unlock them in Hierarchy to edit components"))
                    .font(.caption)
                    .foregroundColor(.warning)
                    .padding(horizontal: 4, vertical: 4)
            } else {
                if addableKinds.isEmpty {
                    actionLabel(symbol: "+",
                                title: L("Add"),
                                color: .accent,
                                isEnabled: false)
                } else {
                    Popover(isPresented: exclusivePresentation(for: .add),
                            width: 280,
                            placement: .end,
                            onKey: dismissOnEscape(.add)) {
                        actionLabel(symbol: "+",
                                    title: L("Add"),
                                    color: .accent,
                                    isEnabled: canMutate)
                    } content: {
                        InspectorComponentPicker(kinds: addableKinds,
                                                 action: .add,
                                                 targetCount: entityIDs.count,
                                                 isPresented: exclusivePresentation(for: .add)) { kind in
                            perform(.add, kind: kind)
                        }
                    }
                }

                if commonKinds.isEmpty {
                    actionLabel(symbol: "↺",
                                title: L("Reset"),
                                color: .onSurfaceVariant,
                                isEnabled: false)
                    actionLabel(symbol: "−",
                                title: L("Remove"),
                                color: .error,
                                isEnabled: false)
                } else {
                    Popover(isPresented: exclusivePresentation(for: .reset),
                            width: 280,
                            placement: .end,
                            onKey: dismissOnEscape(.reset)) {
                        actionLabel(symbol: "↺",
                                    title: L("Reset"),
                                    color: .onSurfaceVariant,
                                    isEnabled: canMutate)
                    } content: {
                        InspectorComponentPicker(kinds: commonKinds,
                                                 action: .reset,
                                                 targetCount: entityIDs.count,
                                                 isPresented: exclusivePresentation(for: .reset)) { kind in
                            perform(.reset, kind: kind)
                        }
                    }

                    Popover(isPresented: exclusivePresentation(for: .remove),
                            width: 280,
                            placement: .end,
                            onKey: dismissOnEscape(.remove)) {
                        actionLabel(symbol: "−",
                                    title: L("Remove"),
                                    color: .error,
                                    isEnabled: canMutate)
                    } content: {
                        InspectorComponentPicker(kinds: commonKinds,
                                                 action: .remove,
                                                 targetCount: entityIDs.count,
                                                 isPresented: exclusivePresentation(for: .remove)) { kind in
                            perform(.remove, kind: kind)
                        }
                    }
                }
            }
        }
        .padding(horizontal: 6, vertical: 4)
    }

    private func actionLabel(symbol: String,
                             title: String,
                             color: SemanticColorRef,
                             isEnabled: Bool) -> some View {
        Row(alignment: .center, spacing: 5) {
            Text(symbol, lineLimit: 1)
                .font(.bodyStrong)
                .foregroundColor(isEnabled ? color : .onSurfaceMuted)
            Text(title, lineLimit: 1)
                .font(.caption)
                .foregroundColor(isEnabled ? .onSurface : .onSurfaceMuted)
        }
        .padding(horizontal: 9, vertical: 5)
        .background(.surfaceSunken)
        .cornerRadius(4)
    }

    /// Component menus are mutually exclusive so a fast switch between Add,
    /// Reset and Remove never leaves stacked portal overlays behind.
    private func exclusivePresentation(for action: InspectorComponentAction) -> Binding<Bool> {
        Binding(
            get: {
                switch action {
                case .add: return isAddPresented
                case .reset: return isResetPresented
                case .remove: return isRemovePresented
                }
            },
            set: { isPresented in
                if isPresented {
                    isAddPresented = action == .add
                    isResetPresented = action == .reset
                    isRemovePresented = action == .remove
                } else {
                    switch action {
                    case .add: isAddPresented = false
                    case .reset: isResetPresented = false
                    case .remove: isRemovePresented = false
                    }
                }
            }
        )
    }

    private func dismissOnEscape(_ action: InspectorComponentAction)
        -> (KeyEvent, EventPhase) -> EventResult {
        { event, phase in
            guard phase == .target || phase == .bubble,
                  event.scancode == ComposeScancode.escape else {
                return .ignored
            }
            exclusivePresentation(for: action).wrappedValue = false
            return .handled
        }
    }

    private func perform(_ action: InspectorComponentAction,
                         kind: EditorComponentKind) {
        let succeeded: Bool
        switch action {
        case .add:
            succeeded = scene.addComponent(kind, to: entityIDs)
        case .reset:
            succeeded = scene.resetComponent(kind, on: entityIDs)
        case .remove:
            succeeded = scene.removeComponent(kind, from: entityIDs)
        }
        if !succeeded {
            store.dispatch(.appendConsoleMessage(
                action.failureMessage,
                severity: .error,
                detail: kind.displayName
            ))
        }
    }
}

private enum InspectorComponentAction: Equatable {
    case add
    case reset
    case remove

    var title: String {
        switch self {
        case .add: return L("Add Component")
        case .reset: return L("Reset Component")
        case .remove: return L("Remove Component")
        }
    }

    var failureMessage: String {
        switch self {
        case .add: return "Could not add component"
        case .reset: return "Could not reset component"
        case .remove: return "Could not remove component"
        }
    }

    var menuRole: MenuItemRole {
        switch self {
        case .remove: return .destructive
        case .add, .reset: return .normal
        }
    }
}

private struct InspectorComponentPicker: View {
    let kinds: [EditorComponentKind]
    let action: InspectorComponentAction
    let targetCount: Int
    let isPresented: Binding<Bool>
    let onSelect: (EditorComponentKind) -> Void
    @State private var searchText: String = ""

    var body: some View {
        let filteredKinds = InspectorComponentFilter.filter(kinds, query: searchText)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 6) {
                Text(action.title)
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .flex()
                EditorPanelBadge("\(targetCount) \(L(targetCount == 1 ? "entity" : "entities"))")
            }
            .padding(horizontal: 9, vertical: 7)

            EditorPanelSearchBar(L("Search Components"),
                                 text: $searchText,
                                 summary: "\(filteredKinds.count)",
                                 onCancel: {
                if searchText.isEmpty {
                    isPresented.wrappedValue = false
                } else {
                    searchText = ""
                }
            })

            Divider()

            if filteredKinds.isEmpty {
                EditorPanelEmptyState(L("No matching components"),
                                      detail: searchText.isEmpty ? nil : "\"\(searchText)\"")
                    .frame(height: 110)
            } else {
                Menu(menuEntries(for: filteredKinds),
                     width: 280,
                     maxVisibleRows: 15,
                     onItemActivated: { isPresented.wrappedValue = false })
            }
        }
        .background(.surface)
        .cornerRadius(5)
        .border(.border, width: 1)
        .clipped()
    }

    private func menuEntries(for filteredKinds: [EditorComponentKind]) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        for category in InspectorComponentCategory.allCases {
            let categoryKinds = filteredKinds.filter { $0.inspectorCategory == category }
            guard !categoryKinds.isEmpty else { continue }
            if !entries.isEmpty {
                entries.append(.separator("component-category-\(category.rawValue)"))
            }
            entries.append(.item(MenuItem(
                id: "component-category-title-\(category.rawValue)",
                title: L(category.displayName),
                isEnabled: false,
                action: {}
            )))
            entries.append(contentsOf: categoryKinds.map { kind in
                .item(MenuItem(
                    id: "\(action)-component-\(kind.rawValue)",
                    title: L(kind.displayName),
                    role: action.menuRole,
                    action: { onSelect(kind) }
                ))
            })
        }
        return entries
    }
}

enum InspectorComponentFilter {
    static func filter(_ kinds: [EditorComponentKind], query: String) -> [EditorComponentKind] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return kinds }
        return kinds.filter { kind in
            kind.displayName.range(of: needle, options: .caseInsensitive) != nil
                || kind.rawValue.range(of: needle, options: .caseInsensitive) != nil
                || kind.inspectorCategory.displayName.range(of: needle,
                                                             options: .caseInsensitive) != nil
        }
    }
}

private enum InspectorComponentCategory: String, CaseIterable {
    case rendering
    case physics
    case animation
    case audio
    case scripting

    var displayName: String {
        switch self {
        case .rendering: return "Rendering"
        case .physics: return "Physics"
        case .animation: return "Animation"
        case .audio: return "Audio"
        case .scripting: return "Scripting"
        }
    }
}

private extension EditorComponentKind {
    var inspectorCategory: InspectorComponentCategory {
        switch self {
        case .renderMesh, .renderMaterial, .camera, .light, .particleEmitter:
            return .rendering
        case .rigidBody, .collider, .characterController, .vehicle, .softBody,
             .cloth, .softBodyMesh, .destructible, .ragdoll:
            return .physics
        case .animationPlayer, .animationGraphPlayer:
            return .animation
        case .audioSource, .audioListener:
            return .audio
        case .script:
            return .scripting
        }
    }
}
