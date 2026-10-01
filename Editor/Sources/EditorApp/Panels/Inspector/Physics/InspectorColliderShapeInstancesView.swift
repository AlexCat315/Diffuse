import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat

/// Per-entity authoring preferences; separate from the authored shape data.
final class InspectorColliderShapeEditorState {
    var selectedIndex: Int? = 0
    var expandedTransformIndices: Set<Int> = []
}

extension InspectorPanel {
    struct InspectorColliderShapeInstancesValue: View {
        let binding: Binding<[ColliderShapeInstance]>
        private let session: InspectorColliderShapeEditorState
        @State private var selectedIndex: Int?
        @State private var expandedTransformIndices: Set<Int>

        init(binding: Binding<[ColliderShapeInstance]>,
             session: InspectorColliderShapeEditorState = InspectorColliderShapeEditorState()) {
            self.binding = binding
            self.session = session
            _selectedIndex = State(wrappedValue: session.selectedIndex)
            _expandedTransformIndices = State(wrappedValue: session.expandedTransformIndices)
        }

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 4) {
                Row(alignment: .center, spacing: 6) {
                    Text("\(binding.wrappedValue.count) \(L("Shapes"))")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Spacer(minLength: 0)
                    Button(L("Add Box"), action: appendShape)
                        .buttonStyle(.ghost)
                        .controlSize(.small)
                        .frame(height: 24)
                        .debugName("collider-add-shape")
                }
                .frame(height: 24)

                if binding.wrappedValue.isEmpty {
                    Text(L("A Collider requires at least one shape."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .padding(vertical: 6)
                } else {
                    for index in binding.wrappedValue.indices {
                        ColliderShapeInstanceRow(binding: binding, index: index,
                                                  selectedIndex: selectionBinding,
                                                  expandedTransforms: transformExpansionBinding)
                            .id(index)
                    }
                }
            }
            .frame(minWidth: 0)
            .debugName("collider-shapes-editor")
            .clipped()
        }

        private var selectionBinding: Binding<Int?> {
            Binding(get: {
                guard let index = selectedIndex, !binding.wrappedValue.isEmpty else { return nil }
                return min(max(0, index), binding.wrappedValue.count - 1)
            }, set: { next in
                session.selectedIndex = next
                selectedIndex = next
            })
        }

        private var transformExpansionBinding: Binding<Set<Int>> {
            Binding(get: { expandedTransformIndices }, set: { next in
                session.expandedTransformIndices = next
                expandedTransformIndices = next
            })
        }

        private func appendShape() {
            var next = binding.wrappedValue
            next.append(ColliderShapeInstance(
                shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)
            ))
            binding.wrappedValue = next
            selectionBinding.wrappedValue = next.count - 1
        }
    }

    private struct ColliderShapeInstanceRow: View {
        let binding: Binding<[ColliderShapeInstance]>
        let index: Int
        let selectedIndex: Binding<Int?>
        let expandedTransforms: Binding<Set<Int>>

        private var isExpanded: Bool { selectedIndex.wrappedValue == index }

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 4) {
                Row(alignment: .center, spacing: 2) {
                    Button(action: {
                        selectedIndex.wrappedValue = isExpanded ? nil : index
                    }) {
                        Row(alignment: .center, spacing: 5) {
                            Icon(isExpanded ? UICommonIcons.chevronDown : UICommonIcons.chevronRight,
                                 size: 10, color: .onSurfaceVariant)
                            Text("#\(index + 1)  \(shapeKindLabel(instance?.shape.kind ?? .box))")
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundColor(.onSurface)
                        }
                        .frame(height: 24)
                        .flex(1, shrink: 1, basis: 0)
                    }
                    .buttonStyle(.ghost)
                    .controlSize(.small)
                    .flex(1, shrink: 1, basis: 0)
                    .debugName("collider-shape-\(index)-disclosure")
                    Button(icon: .resource(UICommonIcons.chevronUp), size: 10,
                           isEnabled: index > 0, tooltip: L("Move shape up"), action: moveUp)
                        .buttonStyle(.ghost)
                        .frame(width: 20, height: 24)
                        .debugName("collider-shape-\(index)-up")
                    Button(icon: .resource(UICommonIcons.chevronDown), size: 10,
                           isEnabled: index + 1 < binding.wrappedValue.count,
                           tooltip: L("Move shape down"), action: moveDown)
                        .buttonStyle(.ghost)
                        .frame(width: 20, height: 24)
                        .debugName("collider-shape-\(index)-down")
                    Button(icon: .resource(UICommonIcons.close),
                           size: 10,
                           isEnabled: binding.wrappedValue.count > 1,
                           tooltip: L("Remove shape"),
                           action: removeShape)
                        .buttonStyle(.ghost)
                        .frame(width: 20, height: 24)
                        .debugName("collider-shape-\(index)-remove")
                }
                .frame(height: 24)
                .background(isExpanded ? .stateLayerSelected : .surfaceVariant.opacity(0.4))

                if isExpanded { expandedEditor }
            }
            .padding(EdgeInsets(bottom: isExpanded ? 4 : 0))
            .frame(minWidth: 0)
            .clipped()
        }

        private var expandedEditor: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 4) {
                labeledWideField(L("Shape")) {
                    EnumField(value: shapeKindBinding, width: 120) { shapeKindLabel($0) }
                }
                geometryFields
                labeledWideField(L("Center")) {
                    Vec3Field(
                        x: shapeCenterBinding(axis: 0),
                        y: shapeCenterBinding(axis: 1),
                        z: shapeCenterBinding(axis: 2),
                        decimals: 2,
                        size: .small
                    )
                }

                DisclosureGroup(L("Local Transform"), isExpanded: transformExpansion) {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        labeledWideField(L("Position")) {
                            Vec3Field(x: vectorBinding(\ColliderShapeInstance.localPosition, axis: 0),
                                      y: vectorBinding(\ColliderShapeInstance.localPosition, axis: 1),
                                      z: vectorBinding(\ColliderShapeInstance.localPosition, axis: 2),
                                      decimals: 2, size: .small)
                                .debugName("collider-shape-\(index)-position")
                        }
                        labeledWideField(L("Scale")) {
                            Vec3Field(x: vectorBinding(\ColliderShapeInstance.localScale, axis: 0, minimum: 0.001),
                                      y: vectorBinding(\ColliderShapeInstance.localScale, axis: 1, minimum: 0.001),
                                      z: vectorBinding(\ColliderShapeInstance.localScale, axis: 2, minimum: 0.001),
                                      decimals: 2, size: .small)
                        }
                        Text(L("Rotation (Quaternion)"))
                            .font(.caption).foregroundColor(.onSurfaceMuted)
                        Row(alignment: .center, spacing: 6) {
                            quaternionField("X", axis: 0)
                            quaternionField("Y", axis: 1)
                        }.frame(height: 24)
                        Row(alignment: .center, spacing: 6) {
                            quaternionField("Z", axis: 2)
                            quaternionField("W", axis: 3)
                        }.frame(height: 24)
                    }
                }
                .debugName("collider-shape-\(index)-transform")
            }
        }

        private var transformExpansion: Binding<Bool> {
            Binding(get: { expandedTransforms.wrappedValue.contains(index) }, set: { expanded in
                var next = expandedTransforms.wrappedValue
                if expanded { next.insert(index) } else { next.remove(index) }
                expandedTransforms.wrappedValue = next
            })
        }

        @ViewBuilder
        private var geometryFields: some View {
            switch instance?.shape ?? .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero) {
            case .box:
                labeledWideField(L("Half Extents")) {
                    Vec3Field(
                        x: boxHalfExtentBinding(axis: 0),
                        y: boxHalfExtentBinding(axis: 1),
                        z: boxHalfExtentBinding(axis: 2),
                        decimals: 2,
                        size: .small
                    )
                }
            case .sphere:
                scalarGeometryField(L("Radius"), binding: radiusBinding)
            case .capsule, .cylinder:
                Row(alignment: .center, spacing: 8) {
                    labeledCompactField(L("Radius")) {
                        geometryNumberField(radiusBinding)
                    }
                    labeledCompactField(L("Half Height")) {
                        geometryNumberField(halfHeightBinding)
                    }
                }
            case .heightField, .mesh, .convex:
                labeledWideField(L("Resource")) {
                    CommitOnBlurTextField(
                        identity: "collider-shape-\(index)-resource",
                        text: resourceBinding,
                        size: .small
                    )
                }
            }
        }

        private func scalarGeometryField(_ label: String, binding: Binding<Float>) -> some View {
            labeledWideField(label) { geometryNumberField(binding) }
        }

        private func geometryNumberField(_ binding: Binding<Float>) -> some View {
            NumberField(value: binding,
                        decimals: 2,
                        size: .small,
                        minValue: 0.01,
                        maxValue: nil,
                        step: 0.1,
                        showsStepper: false)
        }

        private func quaternionField(_ label: String, axis: Int) -> some View {
            Row(alignment: .center, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                NumberField(value: quaternionBinding(axis: axis),
                            decimals: 3,
                            size: .small,
                            minValue: -1,
                            maxValue: 1,
                            step: 0.05,
                            showsStepper: false)
                    .flex(1, shrink: 1, basis: 0)
            }
            .flex(1, shrink: 1, basis: 0)
        }

        private func labeledCompactField<Content: View>(
            _ title: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            Box(direction: .column, alignItems: .stretch, spacing: 3) {
                Text(title)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                content().frame(height: 24).clipped()
            }
            .flex(1, shrink: 1, basis: 0)
        }

        private func labeledWideField<Content: View>(
            _ title: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            Row(alignment: .center, spacing: 8) {
                Text(title)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 58)
                    .clipped()
                content().flex(1, shrink: 1, basis: 0).clipped()
            }
            .frame(height: 28)
        }

        private var instance: ColliderShapeInstance? {
            guard binding.wrappedValue.indices.contains(index) else { return nil }
            return binding.wrappedValue[index]
        }

        private var shapeKindBinding: Binding<ColliderShapeKind> {
            Binding(
                get: { instance?.shape.kind ?? .box },
                set: { kind in
                    updateInstance { value in
                        let center = value.shape.center
                        value.shape = defaultShape(kind, center: center)
                    }
                }
            )
        }

        private func vectorBinding(
            _ keyPath: WritableKeyPath<ColliderShapeInstance, SIMD3<Float>>,
            axis: Int,
            minimum: Float? = nil
        ) -> Binding<Float> {
            Binding(
                get: { instance?[keyPath: keyPath][axis] ?? 0 },
                set: { next in
                    let value = minimum.map { max($0, next) } ?? next
                    updateInstance { $0[keyPath: keyPath][axis] = value }
                }
            )
        }

        private func quaternionBinding(axis: Int) -> Binding<Float> {
            Binding(
                get: { instance?.localRotation[axis] ?? (axis == 3 ? 1 : 0) },
                set: { next in updateInstance { $0.localRotation[axis] = next } }
            )
        }

        private func shapeCenterBinding(axis: Int) -> Binding<Float> {
            Binding(
                get: { instance?.shape.center[axis] ?? 0 },
                set: { next in
                    updateInstance { value in
                        var center = value.shape.center
                        center[axis] = next
                        value.shape = value.shape.replacingCenter(with: center)
                    }
                }
            )
        }

        private func boxHalfExtentBinding(axis: Int) -> Binding<Float> {
            Binding(
                get: {
                    guard case let .box(halfExtents, _) = instance?.shape else { return 0.5 }
                    return halfExtents[axis]
                },
                set: { next in
                    updateInstance { value in
                        guard case let .box(currentHalfExtents, center) = value.shape else { return }
                        var halfExtents = currentHalfExtents
                        halfExtents[axis] = max(0.01, next)
                        value.shape = .box(halfExtents: halfExtents, center: center)
                    }
                }
            )
        }

        private var radiusBinding: Binding<Float> {
            Binding(
                get: {
                    switch instance?.shape {
                    case let .sphere(radius, _),
                         let .capsule(radius, _, _),
                         let .cylinder(radius, _, _): return radius
                    default: return 0.5
                    }
                },
                set: { next in
                    updateInstance { value in
                        let radius = max(0.01, next)
                        switch value.shape {
                        case let .sphere(_, center): value.shape = .sphere(radius: radius, center: center)
                        case let .capsule(_, halfHeight, center):
                            value.shape = .capsule(radius: radius, halfHeight: halfHeight, center: center)
                        case let .cylinder(_, halfHeight, center):
                            value.shape = .cylinder(radius: radius, halfHeight: halfHeight, center: center)
                        default: break
                        }
                    }
                }
            )
        }

        private var halfHeightBinding: Binding<Float> {
            Binding(
                get: {
                    switch instance?.shape {
                    case let .capsule(_, halfHeight, _),
                         let .cylinder(_, halfHeight, _): return halfHeight
                    default: return 0.5
                    }
                },
                set: { next in
                    updateInstance { value in
                        let halfHeight = max(0.01, next)
                        switch value.shape {
                        case let .capsule(radius, _, center):
                            value.shape = .capsule(radius: radius, halfHeight: halfHeight, center: center)
                        case let .cylinder(radius, _, center):
                            value.shape = .cylinder(radius: radius, halfHeight: halfHeight, center: center)
                        default: break
                        }
                    }
                }
            )
        }

        private var resourceBinding: Binding<String> {
            Binding(
                get: { instance?.shape.resourceID ?? "" },
                set: { resourceID in
                    updateInstance { value in
                        let id = resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let resource = id.isEmpty ? nil : id
                        let center = value.shape.center
                        switch value.shape {
                        case .heightField: value.shape = .heightField(resourceID: resource, center: center)
                        case .mesh: value.shape = .mesh(resourceID: resource, center: center)
                        case .convex: value.shape = .convex(resourceID: resource, center: center)
                        default: break
                        }
                    }
                }
            )
        }

        private func updateInstance(_ mutate: (inout ColliderShapeInstance) -> Void) {
            guard binding.wrappedValue.indices.contains(index) else { return }
            var next = binding.wrappedValue
            mutate(&next[index])
            binding.wrappedValue = next
        }

        private func moveUp() { move(to: index - 1) }
        private func moveDown() { move(to: index + 1) }

        private func move(to destination: Int) {
            guard binding.wrappedValue.indices.contains(index),
                  binding.wrappedValue.indices.contains(destination)
            else { return }
            var next = binding.wrappedValue
            next.swapAt(index, destination)
            binding.wrappedValue = next
            let selected = selectedIndex.wrappedValue
            if selected == index { selectedIndex.wrappedValue = destination }
            else if selected == destination { selectedIndex.wrappedValue = index }
            var expanded = expandedTransforms.wrappedValue
            let originExpanded = expanded.remove(index) != nil
            let destinationExpanded = expanded.remove(destination) != nil
            if originExpanded { expanded.insert(destination) }
            if destinationExpanded { expanded.insert(index) }
            expandedTransforms.wrappedValue = expanded
        }

        private func removeShape() {
            guard binding.wrappedValue.count > 1,
                  binding.wrappedValue.indices.contains(index)
            else { return }
            var next = binding.wrappedValue
            next.remove(at: index)
            let previousSelection = selectedIndex.wrappedValue
            binding.wrappedValue = next
            if let selected = previousSelection {
                selectedIndex.wrappedValue = selected == index
                    ? min(index, next.count - 1) : selected > index ? selected - 1 : selected
            }
            expandedTransforms.wrappedValue = Set(expandedTransforms.wrappedValue.compactMap {
                $0 == index ? nil : $0 > index ? $0 - 1 : $0
            })
        }

        private func defaultShape(
            _ kind: ColliderShapeKind,
            center: SIMD3<Float>
        ) -> ColliderShape {
            switch kind {
            case .box: return .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: center)
            case .sphere: return .sphere(radius: 0.5, center: center)
            case .capsule: return .capsule(radius: 0.5, halfHeight: 0.5, center: center)
            case .cylinder: return .cylinder(radius: 0.5, halfHeight: 0.5, center: center)
            case .heightField: return .heightField(resourceID: nil, center: center)
            case .mesh: return .mesh(resourceID: nil, center: center)
            case .convex: return .convex(resourceID: nil, center: center)
            }
        }

        private func shapeKindLabel(_ kind: ColliderShapeKind) -> String {
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
