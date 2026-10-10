extension ComponentInspection {
    static var softBody: Self {
        Self {
            $0.sectionID = "soft-body"
            $0.fields = [
                field("isEnabled", id: "soft-body-enabled", label: "Enabled"),
                field("vertexMass", id: "soft-body-vertex-mass", label: "Vertex Mass", min: 0.0001, step: 0.05),
                field("pressure", id: "soft-body-pressure", label: "Pressure", min: 0, step: 0.1),
                field("linearDamping", id: "soft-body-damping", label: "Linear Damping", min: 0, step: 0.05),
                field("friction", id: "soft-body-friction", label: "Friction", min: 0, step: 0.05),
                field("restitution", id: "soft-body-restitution", label: "Restitution", min: 0, max: 1, step: 0.05),
                field("gravityScale", id: "soft-body-gravity", label: "Gravity Scale", step: 0.1),
                field("vertexRadius", id: "soft-body-vertex-radius", label: "Vertex Radius", min: 0, step: 0.005),
                field("solverIterations", id: "soft-body-iterations", label: "Solver Iterations", min: 1, max: 128, step: 1, kind: .integer),
                field("maxLinearVelocity", id: "soft-body-max-velocity", label: "Max Velocity", min: 0, step: 1),
                field("layerID", id: "soft-body-layer", label: "Layer", min: 0, max: 15, step: 1, kind: .integer),
                field("layerMask", id: "soft-body-layer-mask", label: "Layer Mask", min: 0, max: 65_535, step: 1, kind: .integer),
                field("allowSleep", id: "soft-body-allow-sleep", label: "Allow Sleep"),
                field("facesDoubleSided", id: "soft-body-double-sided", label: "Double Sided"),
                field("selfCollision", id: "soft-body-self-collision", label: "Self Collision"),
            ]
        }
    }

    static var cloth: Self {
        Self {
            $0.sectionID = "cloth"
            $0.fields = [
                field("gridSizeX", id: "cloth-grid-x", label: "Grid X", min: 2, max: 512, step: 1, kind: .integer),
                field("gridSizeZ", id: "cloth-grid-z", label: "Grid Z", min: 2, max: 512, step: 1, kind: .integer),
                field("spacing", id: "cloth-spacing", label: "Spacing", min: 0.001, step: 0.01),
                field("fixedVertexIndices", id: "cloth-fixed-vertices", label: "Fixed Vertex Indices", kind: .json),
                field("compliance", id: "cloth-compliance", label: "Stretch Compliance", min: 0, step: 0.00001),
                field("shearCompliance", id: "cloth-shear-compliance", label: "Shear Compliance", min: 0, step: 0.00001),
                field("bendCompliance", id: "cloth-bend-compliance", label: "Bend Compliance", min: 0, step: 0.00001),
                bendTypeField(id: "cloth-bend-type"),
            ]
        }
    }

    static var softBodyMesh: Self {
        Self {
            $0.sectionID = "soft-body-mesh"
            var resource = field("resourceID", id: "soft-body-mesh-resource", label: "Geometry Resource", kind: .string)
            resource.isNullable = true
            $0.fields = [
                resource,
                field("fixedVertexIndices", id: "soft-body-mesh-fixed", label: "Fixed Vertex Indices", kind: .json),
                field("compliance", id: "soft-body-mesh-compliance", label: "Stretch Compliance", min: 0, step: 0.00001),
                field("shearCompliance", id: "soft-body-mesh-shear", label: "Shear Compliance", min: 0, step: 0.00001),
                field("bendCompliance", id: "soft-body-mesh-bend", label: "Bend Compliance", min: 0, step: 0.00001),
                field("volumeCompliance", id: "soft-body-mesh-volume", label: "Volume Compliance", min: 0, step: 0.00001),
                bendTypeField(id: "soft-body-mesh-bend-type"),
            ]
        }
    }

    private static func bendTypeField(id: String) -> ComponentFieldDescriptor {
        ComponentFieldDescriptor(["bendType"]) {
            $0.id = id
            $0.label = "Bend Type"
            $0.kind = .options
            $0.choices = ClothBendType.allCases.map {
                ComponentFieldChoice(String(describing: $0), value: .unsignedInteger(UInt64($0.rawValue)))
            }
        }
    }
}
