use crate::{core::script_lifecycle::Script, presets::script_presets::ScriptVar};
use diffuse_math::simd::simd_compat::{Float3, simd_length_squared, simd_normalize};
use diffuse_scene::{
    entity_id::EntityID,
    physics::character_controller::{CharacterCommand, CharacterController, CharacterStance},
};
use std::sync::Arc;

impl Script {
    pub fn character_input_controller() -> Self {
        let was_grounded = ScriptVar::new(false);
        Self::default()
            .on_pre_physics(Arc::new(|context| {
                if !context.has_component::<CharacterController>() {
                    return;
                }
                let move_speed = context.float_parameter("moveSpeed").unwrap_or(5.0);
                let jump_speed = context.float_parameter("jumpSpeed").unwrap_or(8.0);
                let crouch_action = context.string_parameter("crouchAction").unwrap_or("crouch");
                let input = context.input();
                let mut direction = Float3::new(input.axis("move_x"), 0.0, -input.axis("move_y"));
                if input.is_held("move_forward") {
                    direction.z -= 1.0;
                }
                if input.is_held("move_back") {
                    direction.z += 1.0;
                }
                if input.is_held("move_left") {
                    direction.x -= 1.0;
                }
                if input.is_held("move_right") {
                    direction.x += 1.0;
                }
                if simd_length_squared(direction) > 0.0 {
                    direction = simd_normalize(direction);
                }
                let stance = if input.is_held(crouch_action) {
                    CharacterStance::Crouching
                } else {
                    CharacterStance::Standing
                };
                context.submit_character_command(CharacterCommand::new(
                    direction * move_speed,
                    input.is_just_pressed("jump"),
                    jump_speed,
                    stance,
                ));
            }))
            .on_update(Arc::new(move |context| {
                let Some(state) = context.character_state() else {
                    return;
                };
                if state.is_grounded() && !was_grounded.get() {
                    context.set_resource(CharacterLandEvent::new(context.entity));
                } else if !state.is_grounded() && was_grounded.get() {
                    context.set_resource(CharacterLeaveGroundEvent::new(context.entity));
                }
                was_grounded.set(state.is_grounded());
            }))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CharacterLandEvent {
    pub entity: EntityID,
}
impl CharacterLandEvent {
    pub fn new(entity: EntityID) -> Self {
        Self { entity }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CharacterLeaveGroundEvent {
    pub entity: EntityID,
}
impl CharacterLeaveGroundEvent {
    pub fn new(entity: EntityID) -> Self {
        Self { entity }
    }
}
