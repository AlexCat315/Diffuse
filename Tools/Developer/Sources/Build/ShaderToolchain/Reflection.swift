internal import Foundation
internal import ToolSupport

/// Reads Slang's reflection document and derives the binding interface that
/// NativeRHI consumes. Every rule mirrors `scripts/compile-rhi-shader.py`.
enum Reflection {
  static func parameterBindings(_ parameter: JSONValue) -> [JSONValue] {
    var bindings: [JSONValue] = []
    if let binding = parameter["binding"] { bindings.append(binding) }
    if let nested = parameter["bindings"]?.arrayValues { bindings.append(contentsOf: nested) }
    return bindings
  }

  static func targetBinding(_ parameter: JSONValue, target: String) -> JSONValue {
    let bindings = parameterBindings(parameter)
    let priorities: [String] =
      target == "metal"
      ? [
        "constantBuffer", "shaderResource", "unorderedAccess", "samplerState",
        "descriptorTableSlot",
      ]
      : [
        "descriptorTableSlot", "constantBuffer", "shaderResource", "unorderedAccess",
        "samplerState",
      ]
    for kind in priorities {
      for binding in bindings where binding["kind"]?.stringValue == kind { return binding }
    }
    return bindings.first ?? .object([])
  }

  static func constants(_ reflection: JSONValue, stage: String) throws -> [JSONValue] {
    var result: [JSONValue] = []
    for parameter in reflection["parameters"]?.arrayValues ?? [] {
      let bindings = parameterBindings(parameter)
      guard bindings.contains(where: { $0["kind"]?.stringValue == "pushConstantBuffer" }) else {
        continue
      }
      let register = bindings.first { $0["kind"]?.stringValue == "descriptorTableSlot" }
      let size = parameter["type"]?["elementVarLayout"]?["binding"]?["size"]?.intValue
      let space = register?["space"]?.intValue ?? 0
      guard let register, let size, space == 0, size > 0, size % 4 == 0, size <= 128 else {
        throw ToolError.message(
          "Push constants require a space0 register and at most 128 aligned bytes")
      }
      result.append(
        .object([
          ("name", parameter["name"] ?? .null),
          ("slot", register["index"] ?? .null),
          ("byteCount", .int(size)),
          ("stage", .string(stage)),
        ]))
    }
    if result.count > 1 {
      throw ToolError.message("At most one push constant block per shader stage is supported")
    }
    return result
  }

  static func bindings(
    _ reflection: JSONValue, target: String = "spirv",
    constants: [JSONValue] = []
  ) throws -> [JSONValue] {
    let constantNames = Set(constants.compactMap { $0["name"]?.stringValue })
    var result: [JSONValue] = []
    for parameter in reflection["parameters"]?.arrayValues ?? [] {
      if let name = parameter["name"]?.stringValue, constantNames.contains(name) { continue }
      let binding = targetBinding(parameter, target: target)
      if binding["kind"]?.stringValue == "specializationConstant" { continue }
      let typeInfo = parameter["type"] ?? .object([])
      let kind = typeInfo["kind"]?.stringValue
      let shape = typeInfo["baseShape"]?.stringValue ?? ""
      let name = parameter["name"]?.stringValue ?? ""
      let resourceType: String
      if kind == "samplerState" {
        resourceType = "sampler"
      } else if kind == "constantBuffer" {
        resourceType = "uniformBuffer"
      } else if kind == "resource" && (shape == "structuredBuffer" || shape == "byteAddressBuffer")
      {
        resourceType = "storageBuffer"
      } else if kind == "resource" && shape.hasPrefix("texture") {
        resourceType = typeInfo["access"]?.stringValue == "readWrite" ? "storageTexture" : "texture"
      } else if kind == "resource" && shape == "accelerationStructure" {
        resourceType = "accelerationStructure"
      } else {
        throw ToolError.message(
          "Unsupported reflected binding '\(name)': \(kind ?? "nil")/\(shape)")
      }
      guard let slot = binding["index"] else {
        throw ToolError.message("Binding '\(name)' has no target resource index")
      }
      var elementStride = 0
      if shape == "structuredBuffer" {
        let sizes = typeInfo["resultType"]?["sizes"]?.arrayValues ?? []
        guard let size = sizes.first(where: { $0["kind"]?.stringValue == "uniform" }),
          let value = size["value"]?.intValue
        else {
          throw ToolError.message("Missing structured element layout for '\(name)'")
        }
        let alignment = size["alignment"]?.intValue ?? 1
        elementStride = ((value + alignment - 1) / alignment) * alignment
      }
      let buffer: JSONValue = .object([
        ("readOnly", .bool(typeInfo["access"]?.stringValue != "readWrite")),
        ("elementStride", .int(elementStride)),
      ])
      result.append(
        .object([
          ("name", .string(name)),
          ("slot", slot),
          ("space", binding["space"] ?? .int(0)),
          ("type", .string(resourceType)),
          ("buffer", buffer),
        ]))
    }
    let slots = result.map { "\($0["space"]?.intValue ?? 0):\($0["slot"]?.intValue ?? 0)" }
    if Set(slots).count != slots.count {
      throw ToolError.message(
        "Target bindings overlap; assign distinct slots before using the RHI direct-binding path")
    }
    return result
  }
}
