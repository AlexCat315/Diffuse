import Foundation

public struct WITFunctionExport: Codable, Sendable, Equatable {
    public var name: String
    public var signature: String
}

public struct WITContract: Codable, Sendable, Equatable {
    public var worldName: String
    public var imports: [String]
    public var exports: [WITFunctionExport]
}

public enum WITContractError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidUTF8
    case missingWorld
    case malformedDeclaration(String)
    case forbiddenImport(String)
    case undeclaredImport(String)
    case missingRequiredExport(String)

    public var description: String {
        switch self {
        case .invalidUTF8: return "capabilities.wit is not valid UTF-8"
        case .missingWorld: return "capabilities.wit must declare one world"
        case let .malformedDeclaration(value): return "malformed WIT declaration: \(value)"
        case let .forbiddenImport(value): return "forbidden WIT import: \(value)"
        case let .undeclaredImport(value): return "WIT import is not granted by plugin.json: \(value)"
        case let .missingRequiredExport(value): return "missing required WIT export: \(value)"
        }
    }
}

/// A deliberately small parser for the authority-bearing parts of WIT. The
/// Wasmtime adapter remains responsible for full WIT/component type matching.
public enum WITContractParser {
    private static let forbiddenImportFragments = [
        "wasi:filesystem", "wasi:http", "wasi:sockets", "wasi:cli/environment",
        "wasi:cli/run", "wasi:random", "wasi:clocks",
    ]

    public static func parse(_ data: Data,
                             grantedImports: Set<PluginImportPermission>) throws -> WITContract {
        guard let source = String(data: data, encoding: .utf8) else {
            throw WITContractError.invalidUTF8
        }
        let clean = strippingComments(source)
        let worlds = captures(pattern: #"\bworld\s+([A-Za-z][A-Za-z0-9_-]*)\s*\{"#,
                              in: clean)
        guard let world = worlds.first else {
            throw WITContractError.missingWorld
        }
        guard worlds.count == 1 else {
            throw WITContractError.malformedDeclaration("exactly one world is required")
        }
        let imports = captures(pattern: #"\bimport\s+([^;\s]+)\s*;"#, in: clean)
        let allowed = Set(grantedImports.map(\.rawValue))
        for imported in imports {
            if forbiddenImportFragments.contains(where: { imported.hasPrefix($0) }) {
                throw WITContractError.forbiddenImport(imported)
            }
            guard allowed.contains(imported) else {
                throw WITContractError.undeclaredImport(imported)
            }
        }
        let exportMatches = matches(pattern: #"\bexport\s+([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(func\s*\([^;]*\)(?:\s*->\s*[^;]+)?)\s*;"#,
                                    in: clean)
        let exports = exportMatches.compactMap { match -> WITFunctionExport? in
            guard match.count == 3 else { return nil }
            return WITFunctionExport(name: match[1], signature: match[2])
        }
        guard Set(exports.map(\.name)).count == exports.count else {
            throw WITContractError.malformedDeclaration("duplicate export names are not allowed")
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
            throw WITContractError.malformedDeclaration(
                "discover must be func() -> string"
            )
        }
        guard normalized["prepare"] == "func(capability-id:string,input:string)->string" else {
            throw WITContractError.malformedDeclaration(
                "prepare must be func(capability-id: string, input: string) -> string"
            )
        }
        return WITContract(worldName: world,
                           imports: imports.sorted(),
                           exports: exports.sorted { $0.name < $1.name })
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
