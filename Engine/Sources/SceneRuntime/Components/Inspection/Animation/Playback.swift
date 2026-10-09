extension ComponentInspection {
    static var animationPlayer: Self {
        Self { inspection in
            inspection.sectionID = "animation-player"
            inspection.inferredFieldsAreAdvanced = true
            inspection.fields = [
                field("clipName", id: "anim-clip", label: "Clip", kind: .string),
                field("speed", id: "anim-speed", label: "Speed", min: 0, max: 10, step: 0.1),
                field("loop", id: "anim-loop", label: "Loop"),
                field("isPlaying", id: "anim-playing", label: "Playing"),
                field("time", label: "Playback Time"),
            ]
            inspection.fields[0].isNullable = true
            inspection.fields[4].isReadOnly = true
            inspection.fields[4].isAdvanced = true
        }
    }
}
