extension ComponentInspection {
    static var constraint: Self {
        // Endpoints are required, so there is no add-menu default. Derive the
        // common fields from the codec without constructing a scene component.
        let endpoint = EntityID(index: 0, generation: 0)
        let example = PhysicsJoint(entityA: endpoint, entityB: endpoint)
        let document = ComponentValue(jsonObject: BuiltinComponentCodecs.serializeConstraint(example, entityA: 0, entityB: 1))
        return Self { inspection in
            inspection.fields = Self().resolvedFields(for: document).map { field in
                var field = field
                if field.path == ["type"] {
                    field.kind = .options
                    field.choices = PhysicsJointKind.allCases.map { ComponentFieldChoice($0.rawValue) }
                } else if field.path == ["entityA"] || field.path == ["entityB"] {
                    field.kind = .integer
                    field.documentation = "Document-local entity index; transaction edits use generation-qualified entity IDs."
                }
                return field
            }
        }
    }

    static var camera: Self {
        Self { $0.fields = [
            field("isActive", id: "camera-active", label: "Active"),
            field("fovYRadians", id: "camera-fov", label: "Field of View", min: 1, max: 179, step: 1, scale: 180 / .pi),
            field("aspectRatio", id: "camera-aspect", label: "Aspect Ratio", min: 0.1, max: 10, step: 0.01),
            field("near", label: "Near", min: 0.0001, step: 0.01),
            field("far", label: "Far", min: 0.1, step: 1),
        ] }
    }

    static var light: Self {
        Self { inspection in
            inspection.fields = [
                field("type", label: "Type", kind: .options, choices: LightType.allCases.map(\.rawValue)),
                field("color", label: "Color", kind: .color),
                field("intensity", label: "Intensity", min: 0, step: 0.1),
                field("range", label: "Range", min: 0, step: 0.1),
                field("spotInnerAngleDegrees", id: "spot-inner-angle", label: "Inner Angle", min: 0, max: 179, step: 1),
                field("spotOuterAngleDegrees", id: "spot-outer-angle", label: "Outer Angle", min: 1, max: 179, step: 1),
            ]
            inspection.fields[3].visibility = .init(path: ["type"], values: [.string("point"), .string("spot")])
            for index in [4, 5] {
                inspection.fields[index].visibility = .init(path: ["type"], values: [.string("spot")])
            }
            inspection.fields[4].numeric.maximumPath = ["spotOuterAngleDegrees"]
        }
    }

    static var audioSource: Self {
        Self { $0.sectionID = "audio-source"; $0.fields = [
            field("clipName", id: "audio-clip", label: "Clip"),
            field("volume", id: "audio-volume", label: "Volume", min: 0, max: 1, step: 0.05),
            field("pitch", id: "audio-pitch", label: "Pitch", min: 0.1, max: 3, step: 0.1),
            field("loop", id: "audio-loop", label: "Loop"),
            field("playOnAwake", id: "audio-play-on-awake", label: "Play on Awake"),
            field("spatialBlend", id: "audio-spatial-blend", label: "Spatial Blend", min: 0, max: 1, step: 0.1),
        ] }
    }

    static var audioListener: Self {
        Self { $0.sectionID = "audio-listener"; $0.fields = [
            field("masterVolume", id: "audio-listener-volume", label: "Master Volume", min: 0, max: 1, step: 0.05),
        ] }
    }

    static var characterController: Self {
        Self { $0.sectionID = "character-controller"; $0.fields = [
            field("radius", id: "character-radius", label: "Radius", min: 0.01, step: 0.05),
            field("standingHalfHeight", id: "character-standing-height", label: "Standing Half Height", min: 0.01, step: 0.05),
            field("crouchingHalfHeight", id: "character-crouching-height", label: "Crouching Half Height", min: 0.01, step: 0.05),
            field("center", id: "character-center", label: "Center"),
            field("maxSlopeDegrees", id: "character-slope", label: "Max Slope", min: 0, max: 89.9, step: 1),
            field("stepHeight", id: "character-step", label: "Step Height", min: 0, step: 0.05),
            field("skinWidth", id: "character-skin", label: "Skin Width", min: 0.001, step: 0.005),
            field("mass", id: "character-mass", label: "Mass", min: 0.01, step: 1),
            field("maxStrength", id: "character-strength", label: "Push Strength", min: 0, step: 10),
            field("gravityScale", id: "character-gravity", label: "Gravity Scale", step: 0.1),
        ] }
    }

    static func field(_ key: String, id: String? = nil, label: String,
        min: Double? = nil, max: Double? = nil, step: Double? = nil, scale: Double = 1,
        kind: ComponentFieldKind = .automatic, choices: [String] = []) -> ComponentFieldDescriptor {
        ComponentFieldDescriptor([key]) { field in
            field.id = id ?? key; field.label = label; field.kind = kind
            field.choices = choices.map { ComponentFieldChoice($0) }
            field.numeric = ComponentNumericPresentation {
                $0.minimum = min; $0.maximum = max; $0.step = step; $0.scale = scale
            }
        }
    }
}
