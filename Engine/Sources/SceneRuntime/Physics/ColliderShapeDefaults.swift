public extension ColliderShapeKind {
    /// Authored dimensions when changing the primary shape. Its centre and the
    /// compound instance transform are retained by the generic field merge.
    var defaultComponentFields: [String: Any] {
        var fields: [String: Any] = ["shape": rawValue]
        switch self {
        case .box: fields["halfExtents"] = [Float](repeating: 0.5, count: 3)
        case .sphere: fields["radius"] = Float(0.5)
        case .capsule, .cylinder:
            fields["radius"] = Float(0.5)
            fields["halfHeight"] = Float(0.5)
        case .heightField, .mesh, .convex: fields["resourceID"] = ""
        }
        return fields
    }
}
