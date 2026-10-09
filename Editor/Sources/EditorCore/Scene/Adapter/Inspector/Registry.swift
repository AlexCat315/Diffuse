import Foundation
import GuavaUIRuntime
import IntentRuntime
import SceneRuntime

extension EditorSceneAdapter {
    func registryInspectorSection(_ schema: ComponentSchema, for entity: EntityID) -> EditorInspectorSection? {
        guard let data = scene.componentData(schema.typeID, for: entity) else { return nil }
        let fields = schema.inspection.resolvedFields(for: data).compactMap { field -> EditorInspectorField? in
            if let visibility = field.visibility,
               !visibility.values.contains(data.value(at: visibility.path) ?? .null) { return nil }
            let value = registryFieldValue(field, schema: schema, entity: entity)
            return EditorInspectorField(id: field.id, label: L(field.label), value: value,
                presentation: field.isAdvanced ? .advanced : .standard, group: field.group)
        }
        return EditorInspectorSection(id: schema.inspection.sectionID ?? schema.typeID,
                                      title: L(schema.displayName), fields: fields)
    }

    private func registryFieldValue(_ field: ComponentFieldDescriptor, schema: ComponentSchema,
                                    entity: EntityID) -> EditorInspectorFieldValue {
        func read(_ path: [String]? = nil) -> ComponentValue {
            scene.componentData(schema.typeID, for: entity)?.value(at: path ?? field.path) ?? .null
        }
        func write(_ value: ComponentValue, path: [String]? = nil) {
            guard !field.isReadOnly, scene.hasComponent(typeID: schema.typeID, for: entity),
                  value.isFiniteJSON, read(path) != value else { return }
            _ = applySceneTransaction(intentVerb: "scene.set_component_data", summary: "Update \(field.label)",
                targetRawIDs: [entity.rawValue], mutations: [.setComponentData(entityID: entity.rawValue,
                    typeID: schema.typeID, value: .fieldPatch(value, at: path ?? field.path), mode: .merge)])
        }
        func number(_ path: [String]) -> Binding<Float> {
            Binding(get: { Float(read(path).numericValue ?? 0) * Float(field.numeric.scale) }, set: { next in
                guard next.isFinite, field.numeric.scale.isFinite, field.numeric.scale != 0 else { return }
                var value = Double(next)
                if let minimum = field.numeric.minimum { value = max(minimum, value) }
                let maximum = field.numeric.maximumPath.flatMap { read($0).numericValue }.map { $0 * field.numeric.scale }
                    ?? field.numeric.maximum
                if let maximum { value = min(maximum, value) }
                write(.number(value / field.numeric.scale), path: path)
            })
        }
        if field.isReadOnly { return .readOnly(componentText(read())) }
        switch field.kind {
        case .boolean:
            return .bool(Binding(get: { if case let .bool(value) = read() { return value }; return false },
                                 set: { write(.bool($0)) }))
        case .string, .options:
            let binding = Binding<String>(get: { if case let .string(value) = read() { return value }; return "" },
                                          set: { next in
                if next.isEmpty && field.isNullable { write(.null) }
                else if field.choices.isEmpty || field.choices.contains(next) { write(.string(next)) }
            })
            if field.kind == .options {
                return .stringOptions(binding, options: field.choices.map {
                    EditorInspectorStringOption(value: $0, label: ComponentFieldDescriptor.displayLabel($0))
                })
            }
            return .text(binding)
        case .number:
            let binding = number(field.path)
            if field.numeric.minimum != nil || field.numeric.maximum != nil || field.numeric.step != nil {
                return .constrainedNumber(binding, min: field.numeric.minimum.map(Float.init),
                    max: field.numeric.maximum.map(Float.init), step: field.numeric.step.map(Float.init), showsStepper: true)
            }
            return .number(binding)
        case .integer:
            // A Float control cannot represent integer seeds or handles exactly.
            return .text(Binding(get: { self.componentText(read()) }, set: { text in
                if let value = UInt64(text) { write(.unsignedInteger(value)) }
                else if let value = Int64(text) { write(.signedInteger(value)) }
            }))
        case .vector3:
            return .vector3(x: number(field.path + ["0"]), y: number(field.path + ["1"]), z: number(field.path + ["2"]))
        case .color:
            return .color(Binding(get: {
                let values = (0..<4).map { read(field.path + [String($0)]).numericValue }
                return Color(r: Float(values[0] ?? 0), g: Float(values[1] ?? 0), b: Float(values[2] ?? 0), a: Float(values[3] ?? 1))
            }, set: { color in
                let count: Int = { if case let .array(values) = read() { return values.count }; return 4 }()
                let channels = Array([color.r, color.g, color.b, color.a].prefix(count == 3 ? 3 : 4))
                guard channels.allSatisfy(\.isFinite) else { return }
                let values = channels.enumerated().map { index, channel -> ComponentValue in
                    var value = max(index == 3 ? 0 : field.color.minimum, Double(channel))
                    if let maximum = index == 3 ? 1 : field.color.maximum { value = min(maximum, value) }
                    return .number(value)
                }
                write(.array(values))
            }))
        case .automatic, .json:
            return .json(Binding(get: { self.componentText(read()) }, set: { text in
                guard let value = try? JSONDecoder().decode(ComponentValue.self, from: Data(text.utf8)) else { return }
                write(value)
            }), minHeight: 100)
        }
    }

    private func componentText(_ value: ComponentValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "null"
    }
}
