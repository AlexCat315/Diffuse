extension BuiltinComponentCodecs {
    static func mergeRigidBody(_ previous: ComponentValue, _ changes: ComponentValue) throws -> ComponentValue {
        let merged = try previous.merging(changes)
        guard case let .object(changes) = changes,
              case let .bool(enabled)? = changes["continuousCollisionDetection"],
              previous.value(at: ["continuousCollisionDetection"]) != .bool(enabled),
              changes["motionQuality"] == nil, case var .object(fields) = merged else { return merged }
        fields["motionQuality"] = .string(enabled ? "linearCast" : "discrete")
        return .object(fields)
    }
}
