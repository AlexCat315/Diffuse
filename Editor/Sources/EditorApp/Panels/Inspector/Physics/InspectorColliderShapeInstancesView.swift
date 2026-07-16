import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat

extension InspectorPanel {
    struct InspectorColliderShapeInstancesValue: View {
        let binding: Binding<[ColliderShapeInstance]>

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Row(alignment: .center, spacing: 8) {
                    Text("\(binding.wrappedValue.count) \(L("Shapes"))")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Spacer(minLength: 0)
                    Button(L("Add Box"), action: appendShape)
                        .buttonStyle(.secondary)
                        .frame(width: 76, height: 24)
                }
                .frame(height: ColliderShapeInstanceEditorLayout.toolbarHeight)

                if binding.wrappedValue.isEmpty {
                    Text(L("A Collider requires at least one shape."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .padding(8)
                        .frame(height: ColliderShapeInstanceEditorLayout.emptyHeight)
                        .background(.surface)
                        .cornerRadius(6)
                        .border(.border, width: 1)
                } else {
                    ScrollView(.vertical,
                               consumePolicy: .always,
                               scrollbarGutter: .stable) {
                        Box(direction: .column,
                            alignItems: .stretch,
                            spacing: ColliderShapeInstanceEditorLayout.cardGap) {
                            for index in binding.wrappedValue.indices {
                                ColliderShapeInstanceCard(binding: binding, index: index)
                            }
                        }
                    }
                    .frame(height: ColliderShapeInstanceEditorLayout.listHeight(
                        shapeCount: binding.wrappedValue.count
                    ))
                }
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surfaceSunken)
            .cornerRadius(6)
            .border(.border, width: 1)
            .frame(height: ColliderShapeInstanceEditorLayout.valueHeight(
                shapeCount: binding.wrappedValue.count
            ))
            .clipped()
        }

        private func appendShape() {
            var next = binding.wrappedValue
            next.append(ColliderShapeInstance(
                shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)
            ))
            binding.wrappedValue = next
        }
    }

    private struct ColliderShapeInstanceCard: View {
        let binding: Binding<[ColliderShapeInstance]>
        let index: Int

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 7) {
                Row(alignment: .center, spacing: 6) {
                    Text("#\(index + 1)")
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                    Text(shapeKindLabel(instance?.shape.kind ?? .box))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Spacer(minLength: 0)
                    Button(L("↑"), isEnabled: index > 0, action: moveUp)
                        .buttonStyle(.ghost)
                        .frame(width: 24, height: 24)
                    Button(L("↓"),
                           isEnabled: index + 1 < binding.wrappedValue.count,
                           action: moveDown)
                        .buttonStyle(.ghost)
                        .frame(width: 24, height: 24)
                    Button(icon: .resource(UICommonIcons.close),
                           size: 10,
                           isEnabled: binding.wrappedValue.count > 1,
                           tooltip: L("Remove shape"),
                           action: removeShape)
                        .buttonStyle(.ghost)
                        .frame(width: 24, height: 24)
                }
                .frame(height: 24)

                labeledWideField(L("Shape")) {
                    EnumField(value: shapeKindBinding, width: 154) { shapeKindLabel($0) }
                }
                labeledWideField(L("Position")) {
                    Vec3Field(
                        x: vectorBinding(\ColliderShapeInstance.localPosition, axis: 0),
                        y: vectorBinding(\ColliderShapeInstance.localPosition, axis: 1),
                        z: vectorBinding(\ColliderShapeInstance.localPosition, axis: 2),
                        decimals: 2,
                        size: .small
                    )
                }
                labeledWideField(L("Rotation")) {
                    Row(alignment: .center, spacing: 3) {
                        quaternionField("X", axis: 0)
                        quaternionField("Y", axis: 1)
                        quaternionField("Z", axis: 2)
                        quaternionField("W", axis: 3)
                    }
                }
                labeledWideField(L("Scale")) {
                    Vec3Field(
                        x: vectorBinding(\ColliderShapeInstance.localScale, axis: 0, minimum: 0.001),
                        y: vectorBinding(\ColliderShapeInstance.localScale, axis: 1, minimum: 0.001),
                        z: vectorBinding(\ColliderShapeInstance.localScale, axis: 2, minimum: 0.001),
                        decimals: 2,
                        size: .small
                    )
                }
                labeledWideField(L("Center")) {
                    Vec3Field(
                        x: shapeCenterBinding(axis: 0),
                        y: shapeCenterBinding(axis: 1),
                        z: shapeCenterBinding(axis: 2),
                        decimals: 2,
                        size: .small
                    )
                }

                geometryFields
            }
            .padding(horizontal: 8, vertical: 8)
            .background(.surface)
            .cornerRadius(6)
            .border(.border, width: 1)
            .frame(height: ColliderShapeInstanceEditorLayout.cardHeight)
            .clipped()
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
                        showsStepper: true)
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
                    .frame(width: 72)
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
        }

        private func removeShape() {
            guard binding.wrappedValue.count > 1,
                  binding.wrappedValue.indices.contains(index)
            else { return }
            var next = binding.wrappedValue
            next.remove(at: index)
            binding.wrappedValue = next
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

enum ColliderShapeInstanceEditorLayout {
    static let toolbarHeight: Float = 28
    static let emptyHeight: Float = 56
    static let cardHeight: Float = 264
    static let cardGap: Float = 6
    static let verticalPadding: Float = 16
    static let contentGap: Float = 8
    static let propertyLabelHeight: Float = 18
    static let propertyVerticalPadding: Float = 12

    static func listHeight(shapeCount: Int) -> Float {
        guard shapeCount > 0 else { return emptyHeight }
        let visibleCount = min(2, max(1, shapeCount))
        return Float(visibleCount) * cardHeight + Float(max(0, visibleCount - 1)) * cardGap
    }

    static func valueHeight(shapeCount: Int) -> Float {
        verticalPadding + toolbarHeight + contentGap + listHeight(shapeCount: shapeCount)
    }

    static func rowHeight(shapeCount: Int) -> Float {
        propertyLabelHeight + propertyVerticalPadding + valueHeight(shapeCount: shapeCount)
    }
}
