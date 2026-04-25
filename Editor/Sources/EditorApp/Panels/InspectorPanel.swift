import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime

struct InspectorPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter

    var body: some View {
        StoreScope(store) { store in
            let entity = scene.entitySummary(id: store.state.selectedEntityID)
            let sections = scene.inspectorSections(for: store.state.selectedEntityID)
            let collapsedIDs = store.state.inspectorCollapsedSectionIDs

            Box(direction: .column, alignItems: .stretch) {
                if let entity {
                    InspectorSelectionSummary(entity: entity,
                                              componentCount: max(0, sections.count - 2))

                    Divider()

                    InspectorSectionControls(sectionIDs: sections.map(\.id),
                                             collapsedCount: collapsedIDs.count,
                                             onSetCollapsed: { ids, isCollapsed in
                        for id in ids {
                            store.dispatch(.setInspectorSectionCollapsed(id: id,
                                                                         isCollapsed: isCollapsed))
                        }
                    })

                    PropertyGrid(propertySections(sections, collapsedIDs: collapsedIDs),
                                 labelWidth: 104,
                                 minValueWidth: 148,
                                 rowHeight: 28,
                                 rowSpacing: 1,
                                 sectionSpacing: 8,
                                 contentPadding: 8,
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
            .frame(minWidth: 280)
        }
    }

    private struct InspectorSelectionSummary: View {
        let entity: EditorSceneEntitySummary
        let componentCount: Int

        var body: some View {
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Row(alignment: .center, spacing: 8) {
                    Box(direction: .column, alignItems: .stretch, spacing: 2) {
                        Text(entity.name)
                            .lineLimit(1)
                            .font(.headline)
                            .foregroundColor(.onSurface)

                        Text(entity.kind)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceVariant)
                    }
                    .flex()

                    Text("#\(entity.id)")
                        .font(.mono)
                        .foregroundColor(.onSurfaceMuted)
                        .padding(horizontal: 8, vertical: 3)
                        .background(.surfaceSunken)
                        .cornerRadius(3)
                }

                Row(alignment: .center, spacing: 6) {
                    Text(L("Components"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Text("\(componentCount)")
                        .font(.mono)
                        .foregroundColor(.onSurface)
                        .padding(horizontal: 6, vertical: 1)
                        .background(.surfaceVariant)
                        .cornerRadius(3)
                    Spacer(minLength: 0)
                }
            }
            .padding(horizontal: 10, vertical: 9)
        }
    }

    private struct InspectorSectionControls: View {
        let sectionIDs: [String]
        let collapsedCount: Int
        let onSetCollapsed: ([String], Bool) -> Void

        var body: some View {
            Row(alignment: .center, spacing: 6) {
                Text(L("Sections"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Text("\(sectionIDs.count - collapsedCount)/\(sectionIDs.count)")
                    .font(.mono)
                    .foregroundColor(.onSurfaceVariant)
                Spacer(minLength: 0)

                Button(L("Expand all"), isEnabled: !sectionIDs.isEmpty) {
                    onSetCollapsed(sectionIDs, false)
                }
                .buttonStyle(.ghost)
                .frame(height: 24)

                Button(L("Collapse all"), isEnabled: !sectionIDs.isEmpty) {
                    onSetCollapsed(sectionIDs, true)
                }
                .buttonStyle(.ghost)
                .frame(height: 24)
            }
            .padding(horizontal: 10, vertical: 6)
            .background(.surfaceSunken)
        }
    }

    private struct InspectorReadOnlyValue: View {
        let text: String

        var body: some View {
            Row(alignment: .center, spacing: 0) {
                Text(text)
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
                    .flex()
            }
            .padding(horizontal: 8, vertical: 4)
            .background(.surface)
            .cornerRadius(3)
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
                    .foregroundColor(.onSurfaceMuted)
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
        let binding: Binding<String>

        var body: some View {
            TextField(text: binding, size: .small)
                .flex()
                .clipped()
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
                case .directional: return "Directional"
                case .point: return "Point"
                case .spot: return "Spot"
                }
            }
        }
    }

    private struct InspectorRigidBodyMotionValue: View {
        let binding: Binding<RigidBodyMotionType>

        var body: some View {
            EnumField(value: binding, width: 150) { type in
                switch type {
                case .static: return "Static"
                case .dynamic: return "Dynamic"
                case .kinematic: return "Kinematic"
                }
            }
        }
    }

    private func propertySections(_ sections: [EditorInspectorSection],
                                  collapsedIDs: Set<String>) -> [PropertyGridSection] {
        sections.map { section in
            let startsCollapsed = collapsedIDs.contains(section.id)
            return PropertyGridSection(
                id: section.id,
                title: section.title,
                rows: section.fields.map { field in
                    PropertyGridRow(id: field.id,
                                    label: field.label,
                                    rowHeight: field.value.preferredRowHeight(defaultHeight: 28)) {
                        fieldView(field.value)
                    }
                },
                isCollapsible: true,
                startsCollapsed: startsCollapsed
            )
        }
    }

    private func fieldView(_ value: EditorInspectorFieldValue) -> some View {
        switch value {
        case let .readOnly(text):
            return AnyView(InspectorReadOnlyValue(text: text))
        case let .text(binding):
            return AnyView(InspectorTextValue(binding: binding))
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
        case let .rigidBodyMotion(binding):
            return AnyView(InspectorRigidBodyMotionValue(binding: binding))
        }
    }

}

private extension EditorInspectorFieldValue {
    func preferredRowHeight(defaultHeight: Float) -> Float? {
        switch self {
        case .vector3:
            return max(defaultHeight, 30)
        case let .json(_, minHeight):
            return max(defaultHeight, minHeight + 34)
        default:
            return nil
        }
    }
}
