import Foundation
import SIMDCompat

extension BuiltinComponentCodecs {
    static func serializeRenderMaterial(_ c: RenderMaterialComponent) -> [String: Any] {
        var d: [String: Any] = [
            "baseColorFactor": vec4ToJSON(c.baseColorFactor),
            "metallicFactor": c.metallicFactor,
            "roughnessFactor": c.roughnessFactor,
            "emissiveFactor": vec3ToJSON(c.emissiveFactor),
        ]
        if let i = c.baseColorTextureIndex { d["baseColorTextureIndex"] = i }
        if let i = c.normalTextureIndex { d["normalTextureIndex"] = i }
        if let value = c.alphaMode { d["alphaMode"] = value.rawValue }
        if let value = c.alphaCutoff { d["alphaCutoff"] = value }
        if let value = c.doubleSided { d["doubleSided"] = value }
        return d
    }

    static func deserializeRenderMaterial(_ d: [String: Any]) -> RenderMaterialComponent {
        RenderMaterialComponent(
            baseColorFactor: jsonToFloatArray(d["baseColorFactor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 1),
            baseColorTextureIndex: jsonToInt(d["baseColorTextureIndex"]),
            normalTextureIndex: jsonToInt(d["normalTextureIndex"]),
            metallicFactor: jsonToFloat(d["metallicFactor"]) ?? 0,
            roughnessFactor: jsonToFloat(d["roughnessFactor"]) ?? 1,
            emissiveFactor: jsonToFloatArray(d["emissiveFactor"]).flatMap(jsonToVec3) ?? .zero,
            alphaMode: jsonToString(d["alphaMode"]).flatMap(MaterialAlphaMode.init(rawValue:)),
            alphaCutoff: jsonToFloat(d["alphaCutoff"]),
            doubleSided: jsonToBool(d["doubleSided"])
        )
    }

    static func serializeAssetReference(_ c: AssetReferenceComponent) -> [String: Any] {
        [
            "assetID": c.assetID,
            "name": c.name,
            "relativePath": c.relativePath,
            "absolutePath": c.absolutePath,
            "kind": c.kind,
            "meshIndex": c.meshIndex,
        ]
    }

    static func deserializeAssetReference(_ d: [String: Any]) -> AssetReferenceComponent {
        AssetReferenceComponent(
            assetID: jsonToString(d["assetID"]) ?? "",
            name: jsonToString(d["name"]) ?? "",
            relativePath: jsonToString(d["relativePath"]) ?? "",
            absolutePath: jsonToString(d["absolutePath"]) ?? "",
            kind: jsonToString(d["kind"]) ?? "",
            meshIndex: jsonToInt(d["meshIndex"]) ?? 0
        )
    }
}
