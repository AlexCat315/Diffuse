import EditorCore
import GuavaUICompose

enum InspectorParticlePropertyLayout {
    private struct Group {
        let id: String
        let title: String
        let startsCollapsed: Bool
        let fieldIDs: [String]
    }

    static func sections(for section: EditorInspectorSection,
                         collapsedIDs: Set<String>,
                         parentStartsCollapsed: Bool,
                         rowBuilder: (EditorInspectorField, String) -> PropertyGridRow) -> [PropertyGridSection] {
        groups.flatMap { group -> [PropertyGridSection] in
            let fields = group.fieldIDs.compactMap { fieldID in
                section.fields.first { $0.id == fieldID }
            }
            guard !fields.isEmpty else { return [] }

            let sectionID = "\(section.id).\(group.id)"
            return [
                PropertyGridSection(
                    id: sectionID,
                    title: group.title,
                    rows: fields.map { rowBuilder($0, sectionID) },
                    isCollapsible: true,
                    startsCollapsed: parentStartsCollapsed
                        || collapsedIDs.contains(sectionID)
                        || group.startsCollapsed
                )
            ]
        }
    }

    private static let groups: [Group] = [
        Group(
            id: "overview",
            title: L("Particle Emitter"),
            startsCollapsed: false,
            fieldIDs: [
                "particle-emitting",
                "particle-looping",
                "particle-duration",
                "particle-simulation-speed",
                "particle-simulation-space",
                "particle-prewarm-time",
                "particle-prewarm-step",
            ]
        ),
        Group(
            id: "emission",
            title: L("Emission"),
            startsCollapsed: false,
            fieldIDs: [
                "particle-rate",
                "particle-rate-curve",
                "particle-distance-rate",
                "particle-distance-rate-curve",
                "particle-burst-count",
                "particle-burst-interval",
                "particle-max",
                "particle-max-spawned-per-frame",
                "particle-max-rendered",
                "particle-lifetime",
            ]
        ),
        Group(
            id: "shape",
            title: L("Shape"),
            startsCollapsed: false,
            fieldIDs: [
                "particle-shape",
                "particle-spawn-radius",
                "particle-box-extents",
                "particle-cone-radius",
                "particle-cone-height",
            ]
        ),
        Group(
            id: "motion",
            title: L("Velocity & Forces"),
            startsCollapsed: false,
            fieldIDs: [
                "particle-velocity-inheritance",
                "particle-gravity",
                "particle-noise-strength",
                "particle-noise-scale",
                "particle-noise-speed",
                "particle-force-mode",
                "particle-force-center",
                "particle-force-axis",
                "particle-force-radius",
                "particle-force-strength",
                "particle-force-falloff",
                "particle-vector-field-mode",
                "particle-vector-field-direction",
                "particle-vector-field-strength",
                "particle-vector-field-scale",
                "particle-vector-field-scroll",
            ]
        ),
        Group(
            id: "appearance",
            title: L("Appearance"),
            startsCollapsed: false,
            fieldIDs: [
                "particle-start-size",
                "particle-end-size",
                "particle-size-randomness",
                "particle-size-curve",
                "particle-rotation",
                "particle-rotation-randomness",
                "particle-angular-velocity",
                "particle-angular-velocity-randomness",
                "particle-start-color",
                "particle-end-color",
                "particle-color-curve",
            ]
        ),
        Group(
            id: "rendering",
            title: L("Rendering"),
            startsCollapsed: false,
            fieldIDs: [
                "particle-blend-mode",
                "particle-render-mode",
                "particle-sort-mode",
                "particle-render-alignment",
                "particle-velocity-stretch-scale",
                "particle-velocity-stretch-max",
                "particle-max-render-distance",
                "particle-render-distance-fade",
                "particle-render-lod-start",
                "particle-render-lod-end",
                "particle-render-lod-min-scale",
                "particle-render-bounds-mode",
                "particle-render-bounds-radius",
                "particle-render-bounds-estimate",
            ]
        ),
        Group(
            id: "collision",
            title: L("Collision"),
            startsCollapsed: true,
            fieldIDs: [
                "particle-collision-mode",
                "particle-collision-plane-y",
                "particle-collision-restitution",
                "particle-collision-damping",
            ]
        ),
        Group(
            id: "texture",
            title: L("Texture Sheet"),
            startsCollapsed: true,
            fieldIDs: [
                "particle-texture",
                "particle-texture-sheet-columns",
                "particle-texture-sheet-rows",
                "particle-texture-sheet-frames",
                "particle-texture-sheet-fps",
                "particle-texture-sheet-playback",
                "particle-texture-sheet-start-frame",
                "particle-texture-sheet-random",
            ]
        ),
        Group(
            id: "trails",
            title: L("Trails & Ribbons"),
            startsCollapsed: true,
            fieldIDs: [
                "particle-trail-length",
                "particle-trail-segments",
                "particle-trail-end-size",
                "particle-trail-end-alpha",
                "particle-ribbon-width-scale",
                "particle-ribbon-tail-width",
                "particle-ribbon-tail-alpha",
                "particle-ribbon-max-segment",
                "particle-ribbon-join-overlap",
                "particle-ribbon-smoothing",
                "particle-ribbon-uv-tiling",
                "particle-ribbon-uv-offset",
            ]
        ),
        Group(
            id: "sub-emitters",
            title: L("Sub Emitters"),
            startsCollapsed: true,
            fieldIDs: [
                "particle-sub-emitter-trigger",
                "particle-sub-emitter-burst",
                "particle-sub-emitter-probability",
                "particle-sub-emitter-depth",
                "particle-sub-emitter-inherit",
                "particle-sub-emitter-lifetime",
                "particle-sub-emitter-velocity",
                "particle-sub-emitter-velocity-random",
                "particle-sub-emitter-start-size",
                "particle-sub-emitter-end-size",
                "particle-sub-emitter-start-color",
                "particle-sub-emitter-end-color",
                "particle-sub-emitters",
            ]
        ),
        Group(
            id: "gpu",
            title: L("GPU Simulation"),
            startsCollapsed: true,
            fieldIDs: [
                "particle-simulation-backend",
                "particle-gpu-workgroup-size",
                "particle-gpu-status",
            ]
        ),
    ]
}
