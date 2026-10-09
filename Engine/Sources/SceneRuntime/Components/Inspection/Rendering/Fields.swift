extension ComponentInspection {
    static var renderMesh: Self {
        Self { inspection in
            inspection.sectionID = "render-mesh"
            inspection.inferredFieldsAreAdvanced = true
            inspection.fields = [
                field("isVisible", id: "mesh-visible", label: "Visible"),
                field("colorTint", id: "mesh-color-tint", label: "Color Tint", kind: .color),
                field("meshIndex", label: "Mesh Index"),
                field("assetID", label: "Asset ID", kind: .string),
            ]
            for index in [2, 3] {
                inspection.fields[index].isReadOnly = true
                inspection.fields[index].isAdvanced = true
            }
        }
    }

    static var renderMaterial: Self {
        Self { inspection in
            inspection.sectionID = "render-material"
            inspection.inferredFieldsAreAdvanced = true
            inspection.fields = [
                field("baseColorFactor", id: "mat-base-color", label: "Base Color", kind: .color),
                field("metallicFactor", id: "mat-metallic", label: "Metallic", min: 0, max: 1, step: 0.05),
                field("roughnessFactor", id: "mat-roughness", label: "Roughness", min: 0, max: 1, step: 0.05),
                field("emissiveFactor", id: "mat-emissive", label: "Emissive", kind: .color),
            ]
            inspection.fields[3].color.maximum = nil
        }
    }
}
