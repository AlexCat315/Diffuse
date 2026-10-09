import Foundation
import SIMDCompat

extension BuiltinComponentCodecs {
    static func serializeLocalTransform(_ transform: LocalTransform) -> [String: Any] {
        let matrix = transform.matrix
        return ["matrix": (0..<4).flatMap { column in (0..<4).map { row in matrix[column][row] } }]
    }

    static func deserializeLocalTransform(_ fields: [String: Any]) -> LocalTransform {
        guard let values = jsonToFloatArray(fields["matrix"]), values.count == 16 else { return .identity }
        return LocalTransform(matrix: simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )))
    }

    static func serializeRenderMesh(_ c: RenderMeshComponent) -> [String: Any] {
        var d: [String: Any] = ["meshIndex": c.meshIndex, "isVisible": c.isVisible]
        d["colorTint"] = vec3ToJSON(c.colorTint)
        if let aid = c.assetID { d["assetID"] = aid }
        if !c.levelsOfDetail.isEmpty { d["levelsOfDetail"] = encodeJSONValue(c.levelsOfDetail) }
        return d
    }

    static func deserializeRenderMesh(_ d: [String: Any]) -> RenderMeshComponent {
        RenderMeshComponent(
            meshIndex: jsonToInt(d["meshIndex"]) ?? 0,
            isVisible: jsonToBool(d["isVisible"]) ?? true,
            colorTint: jsonToFloatArray(d["colorTint"]).flatMap(jsonToVec3) ?? SIMD3<Float>(1, 1, 1),
            assetID: jsonToString(d["assetID"]),
            levelsOfDetail: decodeJSONValue(d["levelsOfDetail"], as: [RenderMeshLOD].self) ?? []
        )
    }

    static func serializeCamera(_ c: CameraComponent) -> [String: Any] {
        [
            "isActive": c.isActive,
            "fovYRadians": c.fovYRadians,
            "aspectRatio": c.aspectRatio,
            "near": c.near,
            "far": c.far,
            "target": vec3ToJSON(c.target),
            "up": vec3ToJSON(c.up),
        ]
    }

    static func deserializeCamera(_ d: [String: Any]) -> CameraComponent {
        CameraComponent(
            target: jsonToFloatArray(d["target"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            up: jsonToFloatArray(d["up"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            fovYRadians: jsonToFloat(d["fovYRadians"]) ?? 1.0,
            aspectRatio: jsonToFloat(d["aspectRatio"]) ?? 1,
            near: jsonToFloat(d["near"]) ?? 0.1,
            far: jsonToFloat(d["far"]) ?? 1000,
            isActive: jsonToBool(d["isActive"]) ?? false
        )
    }

    static func serializeLight(_ c: LightComponent) -> [String: Any] {
        [
            "type": c.type.rawValue,
            "color": vec3ToJSON(c.color),
            "intensity": c.intensity,
            "range": c.range,
            "spotInnerAngleDegrees": c.spotInnerAngleDegrees,
            "spotOuterAngleDegrees": c.spotOuterAngleDegrees,
            "castShadows": c.castShadows,
        ]
    }

    static func deserializeLight(_ d: [String: Any]) -> LightComponent {
        LightComponent(
            type: LightType(rawValue: jsonToString(d["type"]) ?? "point") ?? .point,
            color: jsonToFloatArray(d["color"]).flatMap(jsonToVec3) ?? SIMD3<Float>(1, 1, 1),
            intensity: jsonToFloat(d["intensity"]) ?? 1,
            range: jsonToFloat(d["range"]) ?? 10,
            spotInnerAngleDegrees: jsonToFloat(d["spotInnerAngleDegrees"]) ?? 30,
            spotOuterAngleDegrees: jsonToFloat(d["spotOuterAngleDegrees"]) ?? 45,
            castShadows: jsonToBool(d["castShadows"]) ?? false
        )
    }
}
