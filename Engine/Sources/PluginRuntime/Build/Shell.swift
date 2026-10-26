public import Foundation

/// Builds a Component from a core module compiled by a guest toolchain.
///
/// The shell is a Component whose single placeholder core module carries the
/// imports and exports the WIT contract implies. Compiling the shell yields a
/// valid Component; `link` then swaps the placeholder for the real module, so
/// plugin authors never write WAT.
public enum PluginComponentBuild {
    public struct Shell: Sendable, Equatable {
        /// Component text with a placeholder core module.
        public var wat: String
        /// Guest exports in Swift that adapt the canonical ABI to plain
        /// functions, one per capability, for CovePluginKit packages.
        public var bindings: String
    }

    public enum Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        case unsupportedInput(capability: String)
        case invalidComponent
        case invalidCoreModule

        public var description: String {
            switch self {
            case let .unsupportedInput(capability):
                return "capability '\(capability)' input must be a record of string and list<string> fields"
            case .invalidComponent: return "the compiled shell is not a Component with a core module"
            case .invalidCoreModule: return "the guest module is not a WebAssembly core module"
            }
        }
    }

    public static func shell(for contract: WITContract) throws -> Shell {
        let capabilities = try contract.capabilityInputs.map { input -> (name: String, fields: [ShellField]) in
            guard case let .record(fields) = input.inputType else { throw Error.unsupportedInput(capability: input.name) }
            return (input.name, try fields.map { field in
                switch field.type {
                case .string: return ShellField(name: field.name, isList: false)
                case .list(.string): return ShellField(name: field.name, isList: true)
                default: throw Error.unsupportedInput(capability: input.name)
                }
            })
        }
        return Shell(wat: wat(contract: contract, capabilities: capabilities),
                     bindings: bindings(capabilities))
    }

    /// Replaces the shell's placeholder, its first core module, with `core`.
    public static func link(shell component: Data, core: Data) throws -> Data {
        let componentHeader: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00]
        let coreHeader: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
        guard core.prefix(8).elementsEqual(coreHeader) else { throw Error.invalidCoreModule }
        let bytes = [UInt8](component)
        guard bytes.prefix(8).elementsEqual(componentHeader) else { throw Error.invalidComponent }
        var offset = 8
        while offset < bytes.count {
            let id = bytes[offset]
            guard let (size, sizeBytes) = leb128(bytes, at: offset + 1),
                  offset + 1 + sizeBytes + size <= bytes.count else { throw Error.invalidComponent }
            let payload = offset + 1 + sizeBytes
            if id == 0x01 {
                var linked = Data(bytes[..<offset])
                linked.append(id)
                linked.append(contentsOf: leb128(core.count))
                linked.append(core)
                linked.append(contentsOf: bytes[(payload + size)...])
                return linked
            }
            offset = payload + size
        }
        throw Error.invalidComponent
    }

    struct ShellField {
        let name: String
        let isList: Bool
    }

    private static func leb128(_ bytes: [UInt8], at start: Int) -> (Int, Int)? {
        var value = 0, shift = 0, index = start
        while index < bytes.count, shift < 35 {
            let byte = bytes[index]
            value |= Int(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index - start) }
            shift += 7
        }
        return nil
    }

    private static func leb128(_ value: Int) -> [UInt8] {
        var value = value, result: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }
}
