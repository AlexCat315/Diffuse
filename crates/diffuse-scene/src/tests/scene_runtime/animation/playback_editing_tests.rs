//! Ported from `Engine/Tests/SceneRuntimeTests/Animation/PlaybackEditingTests.swift`.

use std::collections::BTreeMap;

use crate::components::core::registry::ComponentRegistry;
use crate::components::core::value::ComponentValue;
use crate::components::editing::ComponentWriteMode;
use crate::media::animation::AnimationPlayer;
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

fn object<const N: usize>(entries: [(&str, ComponentValue); N]) -> ComponentValue {
    ComponentValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

fn runtime() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// Control edits retain progress; clip changes restart unless the caller supplies
/// a playhead.
#[test]
fn merge_playback() {
    let mut scene = runtime();
    let entity = scene.create_entity();
    scene.set_component(
        AnimationPlayer::new(Some("Walk".to_string()), 1.0, true, true, 7.5),
        entity,
    );

    scene
        .set_component_data(
            &object([
                ("speed", ComponentValue::Number(2.0)),
                ("loop", ComponentValue::Bool(false)),
                ("isPlaying", ComponentValue::Bool(false)),
            ]),
            "animationPlayer",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("merge controls");
    assert_eq!(
        scene.component::<AnimationPlayer>(entity),
        Some(AnimationPlayer::new(
            Some("Walk".to_string()),
            2.0,
            false,
            false,
            7.5
        ))
    );

    scene
        .set_component_data(
            &object([("clipName", ComponentValue::String("Walk".to_string()))]),
            "animationPlayer",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("same clip");
    assert_eq!(
        scene.component::<AnimationPlayer>(entity).map(|player| player.time),
        Some(7.5)
    );

    scene
        .set_component_data(
            &object([("clipName", ComponentValue::String("Run".to_string()))]),
            "animationPlayer",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("different clip");
    assert_eq!(
        scene.component::<AnimationPlayer>(entity).map(|player| player.time),
        Some(0.0)
    );

    scene
        .set_component_data(
            &object([
                ("clipName", ComponentValue::String("Jump".to_string())),
                ("time", ComponentValue::Number(3.0)),
            ]),
            "animationPlayer",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("explicit playhead");
    assert_eq!(
        scene.component::<AnimationPlayer>(entity).map(|player| player.time),
        Some(3.0)
    );

    scene
        .set_component_data(
            &object([("clipName", ComponentValue::Null)]),
            "animationPlayer",
            entity,
            ComponentWriteMode::Merge,
        )
        .expect("cleared clip");
    assert_eq!(
        scene.component::<AnimationPlayer>(entity).and_then(|player| player.clip_name),
        None
    );
    assert_eq!(
        scene.component::<AnimationPlayer>(entity).map(|player| player.time),
        Some(0.0)
    );
    assert!(
        scene
            .component_data("animationPlayer", entity)
            .and_then(|value| value.object_value().cloned())
            .and_then(|fields| fields.get("clipName").cloned())
            .is_none()
    );
}

/// Document replacement and serialization preserve an explicitly stored playback
/// position.
#[test]
fn stored_playhead() {
    let mut scene = runtime();
    let entity = scene.create_entity();
    scene.set_local_transform(LocalTransform::IDENTITY, entity);
    scene.set_component(
        AnimationPlayer::new(Some("Walk".to_string()), 1.0, true, true, 7.5),
        entity,
    );
    scene
        .set_component_data(
            &object([
                ("clipName", ComponentValue::String("Run".to_string())),
                ("time", ComponentValue::Number(12.0)),
            ]),
            "animationPlayer",
            entity,
            ComponentWriteMode::Replace,
        )
        .expect("replace document");
    assert_eq!(
        scene.component::<AnimationPlayer>(entity).map(|player| player.time),
        Some(12.0)
    );

    let data = SceneSerializer::serialize(scene.world()).expect("serialize");
    let mut restored = runtime();
    let created = SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let loaded = created.first().copied().expect("one entity");
    assert_eq!(
        restored
            .component::<AnimationPlayer>(loaded)
            .and_then(|player| player.clip_name),
        Some("Run".to_string())
    );
    assert_eq!(
        restored.component::<AnimationPlayer>(loaded).map(|player| player.time),
        Some(12.0)
    );
    assert_eq!(
        SceneSerializer::serialize(restored.world()).expect("serialize restored"),
        data
    );
}
