import Foundation
import SceneRuntime

extension WorldEvent {
    /// The semantic view still exposes named fields to AI. Keep that projection
    /// at the event boundary; component execution itself only knows the registry.
    static func componentChanges(entityID: UInt64, typeID: String,
                                 value: ComponentValue) -> [WorldEvent] {
        let ref = "scene:\(entityID)"
        var events: [WorldEvent] = [.entityAuthoredChanged(ref: ref,
            property: "components.\(typeID)", value: .json(value))]
        guard let data = value.objectValue else { return events }
        let prefixes = ["rigidbody": "rigidBody", "collider": "collider", "light": "light",
                        "camera": "camera", "audioSource": "audio", "animationPlayer": "animation"]
        let prefix = prefixes[typeID] ?? ""
        let special: [String: [String: String]] = [
            "renderMesh": ["colorTint": "meshColor", "isVisible": "meshIsVisible"],
            "renderMaterial": ["baseColorFactor": "materialBaseColor", "metallicFactor": "materialMetallic",
                "roughnessFactor": "materialRoughness", "emissiveFactor": "materialEmissive"],
            "light": ["spotInnerAngleDegrees": "lightSpotInner", "spotOuterAngleDegrees": "lightSpotOuter"],
            "collider": ["layerID": "colliderLayerID", "layerMask": "colliderLayerMask"],
            "constraint": ["isEnabled": "constraintEnabled"],
            "audioSource": ["clipName": "audioClip"],
            "audioListener": ["masterVolume": "audioListenerMasterVolume"],
            "animationPlayer": ["clipName": "animationClip"],
            "animationGraphPlayer": ["speed": "animationGraphSpeed", "isPlaying": "animationGraphIsPlaying"],
        ]
        for key in data.keys.sorted() {
            let property = special[typeID]?[key] ?? (prefix.isEmpty ? nil : prefix + key.prefix(1).uppercased() + key.dropFirst())
            guard let property, let raw = data[key], let scalar = scalarValue(raw) else { continue }
            events.append(.entityAuthoredChanged(ref: ref, property: property, value: scalar))
        }
        if typeID == "camera", let radians = data["fovYRadians"] as? NSNumber {
            events.append(.entityAuthoredChanged(ref: ref, property: "cameraFovYDegrees",
                value: .float(radians.floatValue * 180 / .pi)))
        }
        if typeID == "collider", let shape = data["shape"] as? String {
            if let radius = data["radius"] as? NSNumber, shape == "sphere" || shape == "capsule" {
                events.append(.entityAuthoredChanged(ref: ref,
                    property: shape == "sphere" ? "colliderSphereRadius" : "colliderCapsuleRadius",
                    value: .float(radius.floatValue)))
            }
            if let value = data["halfExtents"], let scalar = scalarValue(value), shape == "box" {
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderBoxHalfExtents", value: scalar))
            }
            if let height = data["halfHeight"] as? NSNumber, shape == "capsule" {
                events.append(.entityAuthoredChanged(ref: ref, property: "colliderCapsuleHalfHeight", value: .float(height.floatValue)))
            }
        }
        if typeID == "script", let raw = data["bindings"] as? [[String: Any]] {
            let records = raw.map { binding -> [String: Any] in
                var record = binding
                record["handle"] = record.removeValue(forKey: "scriptHandle") ?? 0
                return record
            }
            if let json = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]),
               let text = String(data: json, encoding: .utf8) {
                events.append(.entityAuthoredChanged(ref: ref, property: "scriptBindings", value: .string(text)))
            }
        }
        return events
    }

    private static func scalarValue(_ raw: Any) -> WorldPropertyValue? {
        switch ComponentValue(jsonObject: raw) {
        case let .bool(value): return .bool(value)
        case let .number(value): return .float(Float(value))
        case let .string(value): return .string(value)
        case let .array(values):
            let numbers = values.compactMap { value -> Float? in
                if case let .number(number) = value { return Float(number) }; return nil
            }
            if numbers.count == 3 { return .vec3(numbers[0], numbers[1], numbers[2]) }
            if numbers.count == 4 { return .vec4(numbers[0], numbers[1], numbers[2], numbers[3]) }
            return nil
        default: return nil
        }
    }
}
