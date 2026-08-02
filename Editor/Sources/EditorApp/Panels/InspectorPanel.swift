#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime

struct InspectorPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
    }

    var body: some View {
        StoreScope(store) { store in
            let _ = store.sceneRevision
            let _ = store.uiRefreshRevision
            let selectedEntityID = store.selectedEntityID
            let entity = scene.entitySummary(id: selectedEntityID)
            let sections = scene.inspectorSections(for: selectedEntityID)
            let collapsedIDs = store.inspectorCollapsedSectionIDs

            Box(direction: .column, alignItems: .stretch) {
                if let entity {
                    InspectorSelectionSummary(entity: entity,
                                              componentCount: max(0, sections.count - 2))

                    ComponentActionsBar(scene: scene, entityID: entity.id)

                    PropertyGrid(propertySections(sections,
                                                  collapsedIDs: collapsedIDs,
                                                  entityID: selectedEntityID),
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
                } else {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        Text(L("No selection"))
                            .font(.bodyStrong)
                        Text(L("Select an entity in Hierarchy to inspect SceneRuntime components."))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 300)
        }
    }

    private struct InspectorSelectionSummary: View {
        let entity: EditorSceneEntitySummary
        let componentCount: Int

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
                    Spacer(minLength: 0)
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
                                  entityID: UInt64?) -> [PropertyGridSection] {
        func row(for field: EditorInspectorField, sectionID: String) -> PropertyGridRow {
            PropertyGridRow(id: field.id,
                            label: field.label,
                            rowHeight: field.value.preferredRowHeight(defaultHeight: 28),
                            layout: field.value.preferredRowLayout) {
                fieldView(field.value,
                          identity: "\(entityID.map(String.init) ?? "none")/\(sectionID)/\(field.id)")
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
        case .particleModuleStack:
            return AnyView(EmptyView())
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
    var preferredRowLayout: PropertyGridRowLayout {
        switch self {
        case .colliderShapeInstances, .particleCurve, .particleSubEmitters:
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
        case .particleModuleStack:
            return nil
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
    let scene: EditorSceneAdapter
    let entityID: UInt64
    @State private var isAddPresented: Bool = false
    @State private var isRemovePresented: Bool = false

    var body: some View {
        let addableKinds = scene.addableComponentKinds(on: entityID)
        let removableKinds = scene.componentKinds(on: entityID)
        return Row(alignment: .center, spacing: 6) {
            if scene.isEntityLocked(entityID) {
                Text(L("Locked — unlock in Hierarchy to edit components"))
                    .font(.caption)
                    .foregroundColor(.warning)
                    .padding(horizontal: 4, vertical: 4)
            } else if !addableKinds.isEmpty {
                Popover(isPresented: $isAddPresented, width: 210) {
                    Row(alignment: .center, spacing: 6) {
                        Text("+", lineLimit: 1)
                            .font(.bodyStrong)
                            .foregroundColor(.accent)
                        Text(L("Add Component"), lineLimit: 1)
                            .font(.caption)
                            .foregroundColor(.onSurface)
                    }
                    .padding(horizontal: 10, vertical: 6)
                    .background(.surfaceSunken)
                    .cornerRadius(4)
                } content: {
                    Menu(addableKinds.map { kind in
                        MenuEntry.item(MenuItem(id: "add-component-\(kind.rawValue)",
                                                title: L(kind.displayName),
                                                action: { scene.addComponent(kind, to: entityID) }))
                    }, width: 210, maxVisibleRows: 10, onItemActivated: {
                        isAddPresented = false
                    })
                }
            }

            if !scene.isEntityLocked(entityID), !removableKinds.isEmpty {
                Popover(isPresented: $isRemovePresented, width: 210) {
                    Row(alignment: .center, spacing: 6) {
                        Text("−", lineLimit: 1)
                            .font(.bodyStrong)
                            .foregroundColor(.error)
                        Text(L("Remove Component"), lineLimit: 1)
                            .font(.caption)
                            .foregroundColor(.onSurface)
                    }
                    .padding(horizontal: 10, vertical: 6)
                    .background(.surfaceSunken)
                    .cornerRadius(4)
                } content: {
                    Menu(removableKinds.map { kind in
                        MenuEntry.item(MenuItem(id: "remove-component-\(kind.rawValue)",
                                                title: L(kind.displayName),
                                                role: .destructive,
                                                action: { scene.removeComponent(kind, from: entityID) }))
                    }, width: 210, maxVisibleRows: 10, onItemActivated: {
                        isRemovePresented = false
                    })
                }
            }
        }
        .padding(horizontal: 6, vertical: 4)
    }
}
