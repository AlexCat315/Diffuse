//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Animation.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::{AnimationGraph, AnimationGraphPlayer};

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};

impl EditorSceneAdapter {
    pub(crate) fn animation_graph_player_section(
        &self,
        entity: EntityID,
    ) -> Option<EditorInspectorSection> {
        let player = self.scene().component::<AnimationGraphPlayer>(entity)?;
        let state_count = player.graph.state_machine.states.len();
        let blend_space_count = player.graph.blend_spaces_1d.len();
        let active_state = player
            .active_state
            .clone()
            .unwrap_or_else(|| player.graph.state_machine.initial_state.clone());
        let previous_state = player
            .previous_state
            .clone()
            .unwrap_or_else(|| localized("None"));

        let fields: Vec<EditorInspectorField> = vec![
            EditorInspectorField::new(
                "anim-graph-summary",
                localized("Graph"),
                EditorInspectorFieldValue::ReadOnly(format!(
                    "{state_count} states, {blend_space_count} blend spaces"
                )),
            ),
            EditorInspectorField::new(
                "anim-graph-active",
                localized("Active"),
                EditorInspectorFieldValue::ReadOnly(if active_state.is_empty() {
                    localized("None")
                } else {
                    active_state
                }),
            ),
            EditorInspectorField::new(
                "anim-graph-previous",
                localized("Previous"),
                EditorInspectorFieldValue::ReadOnly(previous_state),
            ),
            EditorInspectorField::new(
                "anim-graph-speed",
                localized("Speed"),
                EditorInspectorFieldValue::ConstrainedNumber {
                    binding: self.animation_graph_speed_binding(entity),
                    min: Some(0.0),
                    max: Some(10.0),
                    step: Some(0.1),
                    shows_stepper: true,
                },
            ),
            EditorInspectorField::new(
                "anim-graph-playing",
                localized("Playing"),
                EditorInspectorFieldValue::Bool(self.animation_graph_is_playing_binding(entity)),
            ),
            EditorInspectorField::new(
                "anim-graph-definition",
                localized("Definition"),
                EditorInspectorFieldValue::Json {
                    binding: self.animation_graph_definition_binding(entity),
                    min_height: 160.0,
                },
            ),
            EditorInspectorField::new(
                "anim-graph-parameters",
                localized("Parameters"),
                EditorInspectorFieldValue::Json {
                    binding: self.animation_graph_parameters_binding(entity),
                    min_height: 84.0,
                },
            ),
        ];
        Some(EditorInspectorSection::new(
            "animation-graph-player",
            localized("Animation Graph"),
            fields,
        ))
    }

    fn animation_graph_definition_binding(&self, entity: EntityID) -> Binding<String> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let Some(graph) = get_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                    .map(|player| player.graph)
                else {
                    return "{}".to_string();
                };
                format_animation_graph(&graph)
            },
            move |next: String| {
                let Some(graph) = parse_animation_graph(&next) else {
                    return;
                };
                let Some(mut player) = set_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                else {
                    return;
                };
                if player.graph == graph {
                    return;
                }
                player.active_state = if graph.state_machine.initial_state.is_empty() {
                    None
                } else {
                    Some(graph.state_machine.initial_state.clone())
                };
                player.previous_state = None;
                player.active_time = 0.0;
                player.previous_time = 0.0;
                player.transition_elapsed = 0.0;
                player.transition_duration = 0.0;
                player.graph = graph;
                set_animation_graph_player(
                    &set_adapter,
                    entity,
                    "scene.set_animation_graph_definition",
                    "Update animation graph definition",
                    player,
                );
            },
        )
    }

    fn animation_graph_speed_binding(&self, entity: EntityID) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                    .map(|player| player.speed)
                    .unwrap_or(1.0)
            },
            move |next: f32| {
                let Some(mut player) = set_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                else {
                    return;
                };
                if player.speed == next {
                    return;
                }
                player.speed = next;
                set_animation_graph_player(
                    &set_adapter,
                    entity,
                    "scene.set_animation_graph_speed",
                    "Update animation graph speed",
                    player,
                );
            },
        )
    }

    fn animation_graph_is_playing_binding(&self, entity: EntityID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                    .map(|player| player.is_playing)
                    .unwrap_or(false)
            },
            move |next: bool| {
                let Some(mut player) = set_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                else {
                    return;
                };
                if player.is_playing == next {
                    return;
                }
                player.is_playing = next;
                set_animation_graph_player(
                    &set_adapter,
                    entity,
                    "scene.set_animation_graph_playing",
                    "Update animation graph playing state",
                    player,
                );
            },
        )
    }

    fn animation_graph_parameters_binding(&self, entity: EntityID) -> Binding<String> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let parameters = get_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                    .map(|player| player.parameters)
                    .unwrap_or_default();
                format_animation_graph_parameters(&parameters)
            },
            move |next: String| {
                let Some(parameters) = parse_animation_graph_parameters(&next) else {
                    return;
                };
                let Some(mut player) = set_adapter
                    .scene()
                    .component::<AnimationGraphPlayer>(entity)
                else {
                    return;
                };
                if player.parameters == parameters {
                    return;
                }
                player.parameters = parameters;
                set_animation_graph_player(
                    &set_adapter,
                    entity,
                    "scene.set_animation_graph_parameters",
                    "Update animation graph parameters",
                    player,
                );
            },
        )
    }
}

fn set_animation_graph_player(
    adapter: &EditorSceneAdapter,
    entity: EntityID,
    intent_verb: &str,
    summary: &str,
    player: AnimationGraphPlayer,
) {
    let registry = adapter.scene().component_registry().clone();
    let mutation =
        SceneMutation::component_data(entity.raw_value(), "animationGraphPlayer", player, registry);
    let _ = adapter.apply_scene_transaction(
        intent_verb,
        summary,
        vec![entity.raw_value()],
        vec![mutation],
    );
}

fn format_animation_graph(graph: &AnimationGraph) -> String {
    diffuse_assets::swift_json::to_sorted_pretty(graph).unwrap_or_else(|_| "{}".to_string())
}

fn parse_animation_graph(text: &str) -> Option<AnimationGraph> {
    serde_json::from_str(text).ok()
}

fn format_animation_graph_parameters(
    parameters: &std::collections::BTreeMap<String, f32>,
) -> String {
    diffuse_assets::swift_json::to_sorted_pretty(parameters).unwrap_or_else(|_| "{}".to_string())
}

fn parse_animation_graph_parameters(text: &str) -> Option<std::collections::BTreeMap<String, f32>> {
    let object: serde_json::Map<String, serde_json::Value> = serde_json::from_str(text).ok()?;
    if !object.values().all(serde_json::Value::is_number) {
        return None;
    }
    Some(
        object
            .into_iter()
            .map(|(key, value)| (key, value.as_f64().unwrap_or(0.0) as f32))
            .collect(),
    )
}
