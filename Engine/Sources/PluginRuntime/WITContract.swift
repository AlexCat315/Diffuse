import CapabilityRuntime
import Foundation

public struct WITFunctionExport: Codable, Sendable, Equatable {
    public var name: String
    public var signature: String

    public init(name: String, signature: String) {
        self.name = name
        self.signature = signature
    }
}

/// One AI-visible capability input derived from the `capabilities` WIT
/// interface. A Component never supplies this schema at runtime.
public struct WITCapabilityInput: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONSchema

    public init(name: String,
                title: String,
                description: String,
                inputSchema: JSONSchema) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct WITContract: Codable, Sendable, Equatable {
    public var worldName: String
    public var imports: [String]
    public var exports: [WITFunctionExport]
    public var capabilityInputs: [WITCapabilityInput]

    public init(worldName: String,
                imports: [String],
                exports: [WITFunctionExport],
                capabilityInputs: [WITCapabilityInput] = []) {
        self.worldName = worldName
        self.imports = imports.sorted()
        self.exports = exports.sorted { $0.name < $1.name }
        self.capabilityInputs = capabilityInputs.sorted { $0.name < $1.name }
    }
}

public enum WITContractError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidUTF8
    case sourceTooLarge
    case missingWorld
    case missingCapabilitiesInterface
    case malformedDeclaration(String)
    case forbiddenImport(String)
    case undeclaredImport(String)
    case missingRequiredExport(String)
    case duplicateType(String)
    case duplicateCapability(String)
    case invalidCapabilityName(String)
    case invalidFieldName(String)
    case unsupportedType(String)
    case unknownType(String)
    case recursiveType(String)
    case typeTooDeep
    case schemaTooLarge

    public var description: String {
        switch self {
        case .invalidUTF8: return "capabilities.wit is not valid UTF-8"
        case .sourceTooLarge: return "capabilities.wit exceeds the 1 MiB limit"
        case .missingWorld: return "capabilities.wit must declare one world"
        case .missingCapabilitiesInterface:
            return "capabilities.wit must declare one 'capabilities' interface"
        case let .malformedDeclaration(value): return "malformed WIT declaration: \(value)"
        case let .forbiddenImport(value): return "forbidden WIT import: \(value)"
        case let .undeclaredImport(value): return "WIT import is not granted by plugin.json: \(value)"
        case let .missingRequiredExport(value): return "missing required WIT export: \(value)"
        case let .duplicateType(value): return "duplicate WIT type: \(value)"
        case let .duplicateCapability(value): return "duplicate WIT capability: \(value)"
        case let .invalidCapabilityName(value): return "invalid WIT capability name: \(value)"
        case let .invalidFieldName(value): return "invalid WIT field name: \(value)"
        case let .unsupportedType(value): return "unsupported WIT capability type: \(value)"
        case let .unknownType(value): return "unknown WIT capability type: \(value)"
        case let .recursiveType(value): return "recursive WIT capability type: \(value)"
        case .typeTooDeep: return "WIT capability types exceed the maximum nesting depth"
        case .schemaTooLarge: return "WIT capability schema exceeds the bounded type limit"
        }
    }
}

/// Parses the small, authority-bearing WIT subset supported by Guava plugins.
///
/// `record <name>-input` declarations inside `interface capabilities` are the
/// only source of AI input schemas. Supported fields are strict records,
/// enums, aliases, option/list, bool/string/char, 8/16/32-bit integers and
/// f32/f64. Free dictionaries, resources, handles and 64-bit JSON integers are
/// rejected at package load time.
public enum WITContractParser {
    private static let maximumSourceBytes = 1 * 1_024 * 1_024
    private static let forbiddenImportFragments = [
        "wasi:filesystem", "wasi:http", "wasi:sockets", "wasi:cli/environment",
        "wasi:cli/run", "wasi:random", "wasi:clocks",
    ]

    public static func parse(_ data: Data,
                             grantedImports: Set<PluginImportPermission>) throws -> WITContract {
        guard data.count <= maximumSourceBytes else { throw WITContractError.sourceTooLarge }
        guard let source = String(data: data, encoding: .utf8) else {
            throw WITContractError.invalidUTF8
        }
        let clean = strippingComments(source)
        let worlds = captures(pattern: #"\bworld\s+([A-Za-z][A-Za-z0-9_-]*)\s*\{"#,
                              in: clean)
        guard let world = worlds.first else { throw WITContractError.missingWorld }
        guard worlds.count == 1 else {
            throw WITContractError.malformedDeclaration("exactly one world is required")
        }
        let imports = captures(pattern: #"\bimport\s+([^;\s]+)\s*;"#, in: clean)
        guard Set(imports).count == imports.count else {
            throw WITContractError.malformedDeclaration("duplicate imports are not allowed")
        }
        let allowed = Set(grantedImports.map(\.rawValue))
        for imported in imports {
            if forbiddenImportFragments.contains(where: { imported.hasPrefix($0) }) {
                throw WITContractError.forbiddenImport(imported)
            }
            guard allowed.contains(imported) else {
                throw WITContractError.undeclaredImport(imported)
            }
        }
        let exportMatches = matches(
            pattern: #"\bexport\s+([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(func\s*\([^;]*\)(?:\s*->\s*[^;]+)?)\s*;"#,
            in: clean
        )
        let exports = exportMatches.compactMap { match -> WITFunctionExport? in
            guard match.count == 3 else { return nil }
            return WITFunctionExport(name: match[1], signature: match[2])
        }
        guard Set(exports.map(\.name)).count == exports.count else {
            throw WITContractError.malformedDeclaration("duplicate export names are not allowed")
        }
        guard exports.count == 2 else {
            throw WITContractError.malformedDeclaration(
                "plugin world must export exactly discover and prepare"
            )
        }
        for required in ["discover", "prepare"] where !exports.contains(where: { $0.name == required }) {
            throw WITContractError.missingRequiredExport(required)
        }
        let normalized = Dictionary(uniqueKeysWithValues: exports.map {
            ($0.name, $0.signature.replacingOccurrences(of: #"\s+"#,
                                                         with: "",
                                                         options: .regularExpression))
        })
        guard normalized["discover"] == "func()->string" else {
            throw WITContractError.malformedDeclaration("discover must be func() -> string")
        }
        guard normalized["prepare"] == "func(capability-id:string,input:string)->string" else {
            throw WITContractError.malformedDeclaration(
                "prepare must be func(capability-id: string, input: string) -> string"
            )
        }

        let capabilityBody = try interfaceBody(named: "capabilities", in: source)
        var typeParser = try CapabilityTypeParser(source: capabilityBody)
        let definitions = try typeParser.parse()
        var schemaBuilder = CapabilitySchemaBuilder(definitions: definitions)
        let inputs = try schemaBuilder.build()
        return WITContract(worldName: world,
                           imports: imports,
                           exports: exports,
                           capabilityInputs: inputs)
    }

    private static func interfaceBody(named name: String, in source: String) throws -> String {
        let pattern = #"\binterface\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw WITContractError.missingCapabilitiesInterface
        }
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: fullRange)
        guard matches.count == 1,
              let declarationRange = Range(matches[0].range, in: source),
              let openingBrace = source[declarationRange].lastIndex(of: "{") else {
            if matches.isEmpty { throw WITContractError.missingCapabilitiesInterface }
            throw WITContractError.malformedDeclaration("exactly one capabilities interface is required")
        }
        let absoluteOpening = openingBrace
        var depth = 1
        var index = source.index(after: absoluteOpening)
        var inLineComment = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inLineComment {
                if character == "\n" || character == "\r" { inLineComment = false }
                index = next
                continue
            }
            if character == "/", next < source.endIndex, source[next] == "/" {
                inLineComment = true
                index = source.index(after: next)
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: absoluteOpening)..<index])
                }
            }
            index = next
        }
        throw WITContractError.malformedDeclaration("unterminated capabilities interface")
    }

    private static func strippingComments(_ source: String) -> String {
        source.replacingOccurrences(of: #"//[^\n\r]*"#,
                                    with: "",
                                    options: .regularExpression)
    }

    private static func captures(pattern: String, in source: String) -> [String] {
        matches(pattern: pattern, in: source).compactMap { $0.count > 1 ? $0[1] : nil }
    }

    private static func matches(pattern: String, in source: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).map { result in
            (0..<result.numberOfRanges).compactMap { index in
                guard let range = Range(result.range(at: index), in: source) else { return nil }
                return String(source[range])
            }
        }
    }
}

private enum CapabilityTypeReference: Equatable {
    case named(String)
    indirect case option(CapabilityTypeReference)
    indirect case list(CapabilityTypeReference)
}

private struct CapabilityField: Equatable {
    var name: String
    var documentation: String
    var type: CapabilityTypeReference
}

private enum CapabilityTypeDefinition: Equatable {
    case record(documentation: String, fields: [CapabilityField])
    case enumeration(documentation: String, cases: [String])
    case alias(documentation: String, type: CapabilityTypeReference)
}

private enum CapabilityToken: Equatable {
    case identifier(String)
    case documentation(String)
    case symbol(Character)
}

private struct CapabilityTypeLexer {
    let source: String

    func lex() throws -> [CapabilityToken] {
        var tokens: [CapabilityToken] = []
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace {
                index = source.index(after: index)
                continue
            }
            if character == "/" {
                let second = source.index(after: index)
                if second < source.endIndex, source[second] == "/" {
                    let third = source.index(after: second)
                    let isDocumentation = third < source.endIndex && source[third] == "/"
                    var end = isDocumentation ? source.index(after: third) : third
                    while end < source.endIndex, source[end] != "\n", source[end] != "\r" {
                        end = source.index(after: end)
                    }
                    if isDocumentation {
                        let textStart = source.index(after: third)
                        let value = source[textStart..<end].trimmingCharacters(in: .whitespaces)
                        tokens.append(.documentation(value))
                    }
                    index = end
                    continue
                }
            }
            if "{}<>:,;=".contains(character) {
                tokens.append(.symbol(character))
                index = source.index(after: index)
                continue
            }
            if character.isLetter {
                var end = source.index(after: index)
                while end < source.endIndex {
                    let value = source[end]
                    guard value.isLetter || value.isNumber || value == "-" else { break }
                    end = source.index(after: end)
                }
                tokens.append(.identifier(String(source[index..<end])))
                index = end
                continue
            }
            throw WITContractError.malformedDeclaration("unexpected character '\(character)'")
        }
        guard tokens.count <= 8_192 else { throw WITContractError.schemaTooLarge }
        return tokens
    }
}

private struct CapabilityTypeParser {
    private var tokens: [CapabilityToken]
    private var index = 0

    init(source: String) throws {
        tokens = try CapabilityTypeLexer(source: source).lex()
    }

    mutating func parse() throws -> [String: CapabilityTypeDefinition] {
        var definitions: [String: CapabilityTypeDefinition] = [:]
        while !isAtEnd {
            let documentation = consumeDocumentation()
            let kind = try consumeIdentifier("type declaration")
            let name = try consumeIdentifier("type name")
            guard name.range(of: #"^[a-z][a-z0-9-]{0,63}$"#,
                             options: .regularExpression) != nil else {
                throw WITContractError.malformedDeclaration("invalid type name '\(name)'")
            }
            let definition: CapabilityTypeDefinition
            switch kind {
            case "record":
                try consumeSymbol("{")
                var fields: [CapabilityField] = []
                var fieldNames: Set<String> = []
                while !peekSymbol("}") {
                    let fieldDocumentation = consumeDocumentation()
                    let fieldName = try consumeIdentifier("record field")
                    guard fieldName.range(of: #"^[a-z][a-z0-9-]{0,63}$"#,
                                         options: .regularExpression) != nil else {
                        throw WITContractError.invalidFieldName(fieldName)
                    }
                    guard fieldNames.insert(fieldName).inserted else {
                        throw WITContractError.malformedDeclaration("duplicate record field '\(fieldName)'")
                    }
                    try consumeSymbol(":")
                    fields.append(CapabilityField(name: fieldName,
                                                  documentation: fieldDocumentation,
                                                  type: try parseTypeReference()))
                    try consumeSeparator(before: "}")
                    guard fields.count <= 64 else { throw WITContractError.schemaTooLarge }
                }
                try consumeSymbol("}")
                consumeOptionalTerminator()
                definition = .record(documentation: documentation, fields: fields)
            case "enum":
                try consumeSymbol("{")
                var cases: [String] = []
                var seen: Set<String> = []
                while !peekSymbol("}") {
                    _ = consumeDocumentation()
                    let value = try consumeIdentifier("enum case")
                    guard seen.insert(value).inserted else {
                        throw WITContractError.malformedDeclaration("duplicate enum case '\(value)'")
                    }
                    cases.append(value)
                    try consumeSeparator(before: "}")
                    guard cases.count <= 128 else { throw WITContractError.schemaTooLarge }
                }
                try consumeSymbol("}")
                consumeOptionalTerminator()
                guard !cases.isEmpty else {
                    throw WITContractError.malformedDeclaration("enum '\(name)' must not be empty")
                }
                definition = .enumeration(documentation: documentation, cases: cases)
            case "type":
                try consumeSymbol("=")
                definition = .alias(documentation: documentation,
                                    type: try parseTypeReference())
                try consumeSymbol(";")
            default:
                throw WITContractError.malformedDeclaration(
                    "unsupported declaration '\(kind)'; expected record, enum, or type"
                )
            }
            guard definitions.updateValue(definition, forKey: name) == nil else {
                throw WITContractError.duplicateType(name)
            }
            guard definitions.count <= 128 else { throw WITContractError.schemaTooLarge }
        }
        return definitions
    }

    private mutating func parseTypeReference() throws -> CapabilityTypeReference {
        let name = try consumeIdentifier("field type")
        if name == "option" || name == "list" {
            try consumeSymbol("<")
            let child = try parseTypeReference()
            try consumeSymbol(">")
            return name == "option" ? .option(child) : .list(child)
        }
        return .named(name)
    }

    private var isAtEnd: Bool { index >= tokens.count }

    private mutating func consumeDocumentation() -> String {
        var lines: [String] = []
        while index < tokens.count {
            guard case let .documentation(line) = tokens[index] else { break }
            lines.append(line)
            index += 1
        }
        return CapabilityContract.sanitiseMetadata(lines.joined(separator: " "),
                                                   maximumLength: 512)
    }

    private mutating func consumeIdentifier(_ context: String) throws -> String {
        guard index < tokens.count,
              case let .identifier(value) = tokens[index] else {
            throw WITContractError.malformedDeclaration("expected \(context)")
        }
        index += 1
        return value
    }

    private func peekSymbol(_ value: Character) -> Bool {
        guard index < tokens.count, case let .symbol(found) = tokens[index] else { return false }
        return found == value
    }

    private mutating func consumeSymbol(_ value: Character) throws {
        guard peekSymbol(value) else {
            throw WITContractError.malformedDeclaration("expected '\(value)'")
        }
        index += 1
    }

    private mutating func consumeSeparator(before closing: Character) throws {
        if peekSymbol(",") || peekSymbol(";") {
            index += 1
        } else if !peekSymbol(closing) {
            throw WITContractError.malformedDeclaration("expected ',' or '\(closing)'")
        }
    }

    private mutating func consumeOptionalTerminator() {
        if peekSymbol(";") { index += 1 }
    }
}

private struct CapabilitySchemaBuilder {
    let definitions: [String: CapabilityTypeDefinition]
    private var nodeCount = 0

    init(definitions: [String: CapabilityTypeDefinition]) {
        self.definitions = definitions
    }

    mutating func build() throws -> [WITCapabilityInput] {
        let capabilityNames = definitions.keys.filter { $0.hasSuffix("-input") }.sorted()
        guard capabilityNames.count <= PluginResourceLimits.secureDefault.maximumCapabilities else {
            throw WITContractError.schemaTooLarge
        }
        var seen: Set<String> = []
        return try capabilityNames.map { typeName in
            let localName = String(typeName.dropLast("-input".count))
            guard !localName.isEmpty,
                  localName.range(of: #"^[a-z][a-z0-9-]{0,63}$"#,
                                  options: .regularExpression) != nil else {
                throw WITContractError.invalidCapabilityName(localName)
            }
            guard seen.insert(localName).inserted else {
                throw WITContractError.duplicateCapability(localName)
            }
            guard case let .record(documentation, _) = definitions[typeName] else {
                throw WITContractError.malformedDeclaration(
                    "capability '\(typeName)' must be a record"
                )
            }
            let schema = try schema(forNamed: typeName, depth: 0, stack: [])
            return WITCapabilityInput(name: localName,
                                      title: Self.humanisedTitle(localName),
                                      description: documentation,
                                      inputSchema: schema)
        }
    }

    private mutating func schema(for reference: CapabilityTypeReference,
                                 depth: Int,
                                 stack: [String]) throws -> JSONSchema {
        guard depth <= 12 else { throw WITContractError.typeTooDeep }
        nodeCount += 1
        guard nodeCount <= 256 else { throw WITContractError.schemaTooLarge }
        switch reference {
        case let .option(child):
            return .choice([try schema(for: child, depth: depth + 1, stack: stack), .null()])
        case let .list(child):
            return .array(of: try schema(for: child, depth: depth + 1, stack: stack),
                          maximumItems: 4_096)
        case let .named(name):
            switch name {
            case "bool": return .boolean()
            case "string": return .string(minLength: nil, maxLength: 65_536)
            case "char": return .string(minLength: 1, maxLength: 1)
            case "u8": return .integer(minimum: 0, maximum: 255)
            case "u16": return .integer(minimum: 0, maximum: 65_535)
            case "u32": return .integer(minimum: 0, maximum: Int(UInt32.max))
            case "s8": return .integer(minimum: -128, maximum: 127)
            case "s16": return .integer(minimum: -32_768, maximum: 32_767)
            case "s32": return .integer(minimum: Int(Int32.min), maximum: Int(Int32.max))
            case "f32", "f64": return .number()
            case "u64", "s64": throw WITContractError.unsupportedType(name)
            default: return try schema(forNamed: name, depth: depth, stack: stack)
            }
        }
    }

    private mutating func schema(forNamed name: String,
                                 depth: Int,
                                 stack: [String]) throws -> JSONSchema {
        guard let definition = definitions[name] else { throw WITContractError.unknownType(name) }
        guard !stack.contains(name) else { throw WITContractError.recursiveType(name) }
        let nextStack = stack + [name]
        switch definition {
        case let .record(documentation, fields):
            var properties: [String: JSONSchema] = [:]
            var required: [String] = []
            for field in fields {
                let isOptional: Bool
                let fieldType: CapabilityTypeReference
                if case let .option(child) = field.type {
                    isOptional = true
                    fieldType = child
                } else {
                    isOptional = false
                    fieldType = field.type
                }
                var child = try schema(for: fieldType,
                                       depth: depth + 1,
                                       stack: nextStack)
                if !field.documentation.isEmpty { child.description = field.documentation }
                properties[field.name] = child
                if !isOptional { required.append(field.name) }
            }
            return .object(properties: properties,
                           required: required,
                           description: documentation.isEmpty ? nil : documentation)
        case let .enumeration(documentation, cases):
            return .string(description: documentation.isEmpty ? nil : documentation,
                           allowedValues: cases)
        case let .alias(documentation, type):
            var result = try schema(for: type, depth: depth + 1, stack: nextStack)
            if !documentation.isEmpty { result.description = documentation }
            return result
        }
    }

    private static func humanisedTitle(_ value: String) -> String {
        value.split(separator: "-")
            .map { word in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
