public import Foundation
public import CapabilityRuntime

/// Static metadata emitted by the TypeScript SDK. Inspecting a package never executes its code.
public enum BunPluginContract {
    private struct Document: Decodable { let version: Int; let entries: [Entry] }
    private struct Entry: Decodable {
        let name: String
        let title: String?
        let description: String?
        let input: PluginJSON
    }

    public static func decode(_ data: Data, imports: [PluginImportPermission]) throws -> PluginContract {
        guard data.count <= 1_024 * 1_024 else { throw PluginContractError.sourceTooLarge }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.entries.count <= 64,
              Set(document.entries.map(\.name)).count == document.entries.count else {
            throw PluginManifestValidationError.invalidContribution("capabilities.json")
        }
        let entries = try document.entries.map { entry in
            guard entry.name.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
                throw PluginContractError.invalidCapabilityName(entry.name)
            }
            let (type, schema) = try input(entry.input, depth: 0)
            guard case .record = type else { throw PluginContractError.unsupportedType("entry input must be an object") }
            return PluginEntryContract(name: entry.name, title: entry.title ?? entry.name, description: entry.description ?? "",
                                      inputSchema: schema, inputType: type)
        }
        return PluginContract(imports: imports.map(\.rawValue), capabilityInputs: entries)
    }

    private static func input(_ value: PluginJSON, depth: Int) throws -> (PluginInputType, JSONSchema) {
        guard depth < 16 else { throw PluginContractError.typeTooDeep }
        switch value {
        case .string("string"): return (.string, .string(minLength: nil, maxLength: 65_536))
        case .string("bool"): return (.bool, JSONSchema(type: .boolean))
        case .string("number"): return (.f64, .number())
        case .string("integer"): return (.s32, JSONSchema(type: .integer, minimum: Double(Int32.min), maximum: Double(Int32.max)))
        case let .object(fields) where fields.count == 1:
            if let child = fields["optional"] {
                let (type, schema) = try input(child, depth: depth + 1)
                return (.option(type), JSONSchema(oneOf: [schema, JSONSchema(type: .null)]))
            }
            if case let .array(values) = fields["enum"], !values.isEmpty, values.count <= 256 {
                let names = values.compactMap(\.stringValue)
                guard names.count == values.count, Set(names).count == names.count else { throw PluginContractError.unsupportedType("enum") }
                return (.enumeration(names), .string(allowedValues: names))
            }
            if case let .array(values) = fields["oneOf"], !values.isEmpty, values.count <= 16 {
                let children = try values.map { try input($0, depth: depth + 1) }
                return (.oneOf(children.map(\.0)), JSONSchema(oneOf: children.map(\.1)))
            }
            if let child = fields["list"] {
                let (type, schema) = try input(child, depth: depth + 1)
                return (.list(type), .array(of: schema, maximumItems: 4096))
            }
            if case let .object(properties) = fields["record"], properties.count <= 128 {
                var types: [PluginInputField] = []
                var schemas: [String: JSONSchema] = [:]
                var required: [String] = []
                for name in properties.keys.sorted() {
                    guard name.range(of: #"^[a-z][a-zA-Z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
                        throw PluginContractError.invalidFieldName(name)
                    }
                    let (type, schema) = try input(properties[name]!, depth: depth + 1)
                    types.append(PluginInputField(name: name, type: type)); schemas[name] = schema
                    if case .option = type {} else { required.append(name) }
                }
                return (.record(types), .object(properties: schemas, required: required))
            }
            fallthrough
        default: throw PluginContractError.unsupportedType("capabilities.json input")
        }
    }
}
