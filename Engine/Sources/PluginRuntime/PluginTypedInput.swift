import Foundation

public enum PluginTypedInputError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidJSON
    case typeMismatch(path: String, expected: String)
    case missingField(path: String)
    case invalidEnum(path: String)
    case numericOverflow(path: String)
    case valueTooLarge

    public var description: String {
        switch self {
        case .invalidJSON: return "plugin capability input is not valid JSON"
        case let .typeMismatch(path, expected):
            return "plugin capability input \(path) must be \(expected)"
        case let .missingField(path): return "plugin capability input is missing \(path)"
        case let .invalidEnum(path): return "plugin capability input \(path) is not an allowed enum case"
        case let .numericOverflow(path): return "plugin capability input \(path) exceeds its WIT numeric type"
        case .valueTooLarge: return "typed plugin capability input exceeds 1 MiB"
        }
    }
}

/// Encodes already validated JSON into a compact, versioned value stream. The
/// C bridge decodes this stream against Wasmtime's reflected parameter type;
/// the Component never receives or parses the original JSON document.
public enum PluginTypedInputEncoder {
    public static let maximumBytes = 1 * 1_024 * 1_024
    private static let magic = Data([0x47, 0x54, 0x56, 0x31]) // GTV1

    public static func encode(_ data: Data,
                              as type: WITValueType,
                              maximumBytes: Int = PluginTypedInputEncoder.maximumBytes) throws -> Data {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data,
                                                     options: [.fragmentsAllowed])
        } catch {
            throw PluginTypedInputError.invalidJSON
        }
        var output = magic
        try append(value, as: type, path: "$", to: &output,
                   maximumBytes: min(maximumBytes, Self.maximumBytes))
        guard output.count <= maximumBytes else {
            throw PluginTypedInputError.valueTooLarge
        }
        return output
    }

    private static func append(_ value: Any,
                               as type: WITValueType,
                               path: String,
                               to output: inout Data,
                               maximumBytes: Int) throws {
        switch type {
        case .bool:
            guard let boolean = booleanValue(value) else {
                throw PluginTypedInputError.typeMismatch(path: path, expected: "bool")
            }
            output.append(boolean ? 1 : 0)
        case .string:
            guard let string = value as? String else {
                throw PluginTypedInputError.typeMismatch(path: path, expected: "string")
            }
            try appendString(string, path: path, to: &output,
                             maximumBytes: maximumBytes)
        case .character:
            guard let string = value as? String,
                  string.unicodeScalars.count == 1,
                  let scalar = string.unicodeScalars.first else {
                throw PluginTypedInputError.typeMismatch(path: path,
                                                         expected: "one Unicode scalar")
            }
            appendFixed(UInt32(scalar.value), to: &output)
        case .u8:
            output.append(UInt8(try integer(value, path: path,
                                            minimum: 0, maximum: 255)))
        case .u16:
            appendFixed(UInt16(try integer(value, path: path,
                                           minimum: 0, maximum: 65_535)),
                        to: &output)
        case .u32:
            appendFixed(UInt32(try integer(value, path: path,
                                           minimum: 0,
                                           maximum: Int64(UInt32.max))),
                        to: &output)
        case .s8:
            output.append(UInt8(bitPattern: Int8(try integer(
                value, path: path, minimum: -128, maximum: 127
            ))))
        case .s16:
            appendFixed(UInt16(bitPattern: Int16(try integer(
                value, path: path, minimum: -32_768, maximum: 32_767
            ))), to: &output)
        case .s32:
            appendFixed(UInt32(bitPattern: Int32(try integer(
                value,
                path: path,
                minimum: Int64(Int32.min),
                maximum: Int64(Int32.max)
            ))), to: &output)
        case .f32:
            guard let number = numericValue(value) else {
                throw PluginTypedInputError.typeMismatch(path: path, expected: "f32")
            }
            let narrowed = Float(number)
            guard narrowed.isFinite else {
                throw PluginTypedInputError.numericOverflow(path: path)
            }
            appendFixed(narrowed.bitPattern, to: &output)
        case .f64:
            guard let number = numericValue(value), number.isFinite else {
                throw PluginTypedInputError.typeMismatch(path: path, expected: "f64")
            }
            appendFixed(number.bitPattern, to: &output)
        case let .list(child):
            guard let values = value as? [Any], values.count <= 4_096 else {
                throw PluginTypedInputError.typeMismatch(path: path,
                                                         expected: "a list of at most 4096 items")
            }
            appendFixed(UInt32(values.count), to: &output)
            for (index, element) in values.enumerated() {
                try append(element, as: child, path: "\(path)[\(index)]",
                           to: &output, maximumBytes: maximumBytes)
            }
        case let .option(child):
            if value is NSNull {
                output.append(0)
            } else {
                output.append(1)
                try append(value, as: child, path: path, to: &output,
                           maximumBytes: maximumBytes)
            }
        case let .record(fields):
            guard let object = value as? [String: Any] else {
                throw PluginTypedInputError.typeMismatch(path: path, expected: "record")
            }
            let allowedFields = Set(fields.map(\.name))
            guard Set(object.keys).isSubset(of: allowedFields) else {
                throw PluginTypedInputError.typeMismatch(path: path,
                                                         expected: "a strict WIT record")
            }
            for field in fields {
                let fieldPath = "\(path).\(field.name)"
                if case let .option(child) = field.type {
                    guard let fieldValue = object[field.name], !(fieldValue is NSNull) else {
                        output.append(0)
                        continue
                    }
                    output.append(1)
                    try append(fieldValue, as: child, path: fieldPath,
                               to: &output, maximumBytes: maximumBytes)
                } else {
                    guard let fieldValue = object[field.name] else {
                        throw PluginTypedInputError.missingField(path: fieldPath)
                    }
                    try append(fieldValue, as: field.type, path: fieldPath,
                               to: &output, maximumBytes: maximumBytes)
                }
            }
        case let .enumeration(cases):
            guard let value = value as? String,
                  let index = cases.firstIndex(of: value) else {
                throw PluginTypedInputError.invalidEnum(path: path)
            }
            appendFixed(UInt32(index), to: &output)
        }
        guard output.count <= maximumBytes else {
            throw PluginTypedInputError.valueTooLarge
        }
    }

    private static func appendString(_ string: String,
                                     path: String,
                                     to output: inout Data,
                                     maximumBytes: Int) throws {
        let bytes = Data(string.utf8)
        guard bytes.count <= maximumBytes else {
            throw PluginTypedInputError.typeMismatch(path: path,
                                                     expected: "a bounded UTF-8 string")
        }
        appendFixed(UInt32(bytes.count), to: &output)
        output.append(bytes)
    }

    private static func integer(_ value: Any,
                                path: String,
                                minimum: Int64,
                                maximum: Int64) throws -> Int64 {
        guard let number = numericValue(value),
              number.isFinite,
              number.rounded() == number else {
            throw PluginTypedInputError.typeMismatch(path: path, expected: "integer")
        }
        guard number >= Double(minimum), number <= Double(maximum) else {
            throw PluginTypedInputError.numericOverflow(path: path)
        }
        return Int64(number)
    }

    private static func numericValue(_ value: Any) -> Double? {
        guard booleanValue(value) == nil else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private static func booleanValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func appendFixed<T: FixedWidthInteger>(_ value: T,
                                                           to output: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { output.append(contentsOf: $0) }
    }
}
