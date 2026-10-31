//! `Inspection/Animation/Playback.swift` — the animation player form.
//!
//! `clipName` is nullable (clearing it writes `null`, and the codec omits the
//! key); the playhead is a read-only advanced field because transactions own it.

use crate::components::inspection::builtin_inspection::{field, ComponentFieldSpec};
use crate::components::inspection::inspection::{ComponentFieldKind, ComponentInspection};

impl ComponentInspection {
    /// Swift `animationPlayer`.
    pub fn animation_player() -> Self {
        let mut inspection = ComponentInspection {
            section_id: Some("animation-player".to_string()),
            inferred_fields_are_advanced: true,
            fields: vec![
                field(
                    ComponentFieldSpec::new("clipName", "Clip")
                        .id("anim-clip")
                        .kind(ComponentFieldKind::String),
                ),
                field(
                    ComponentFieldSpec::new("speed", "Speed")
                        .id("anim-speed")
                        .minimum(0.0)
                        .maximum(10.0)
                        .step(0.1),
                ),
                field(ComponentFieldSpec::new("loop", "Loop").id("anim-loop")),
                field(ComponentFieldSpec::new("isPlaying", "Playing").id("anim-playing")),
                field(ComponentFieldSpec::new("time", "Playback Time")),
            ],
            ..ComponentInspection::default()
        };
        inspection.fields[0].is_nullable = true;
        inspection.fields[4].is_read_only = true;
        inspection.fields[4].is_advanced = true;
        inspection
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_playhead_is_read_only_and_advanced() {
        let inspection = ComponentInspection::animation_player();
        assert_eq!(inspection.section_id.as_deref(), Some("animation-player"));
        assert!(inspection.inferred_fields_are_advanced);
        assert!(inspection.fields[0].is_nullable);
        let time = &inspection.fields[4];
        assert_eq!(time.path, vec!["time".to_string()]);
        assert!(time.is_read_only);
        assert!(time.is_advanced);
        assert!(!inspection.fields[1].is_read_only);
    }
}
