use super::script_c_bridge_context::with_current_context;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::physics::character_controller::{CharacterCommand, CharacterStance};
use diffuse_script_api::abi::HostApi;
use std::ffi::c_void;

pub(crate) fn install(table: &mut HostApi) {
    table.submit_character_command = Some(submit_character_command);
    table.character_is_grounded = Some(character_is_grounded);
    table.character_ground_state = Some(character_ground_state);
    table.character_velocity = Some(character_velocity);
}
extern "C" fn submit_character_command(
    instance: *mut c_void,
    vx: f32,
    vy: f32,
    vz: f32,
    jump: bool,
    jump_speed: f32,
    stance: u8,
) {
    with_current_context(instance, (), |context| {
        let stance = if stance == 1 {
            CharacterStance::Crouching
        } else {
            CharacterStance::Standing
        };
        context.submit_character_command(CharacterCommand::new(
            Float3::new(vx, vy, vz),
            jump,
            jump_speed,
            stance,
        ));
    });
}
extern "C" fn character_is_grounded(instance: *mut c_void) -> bool {
    with_current_context(instance, false, |context| {
        context
            .character_state()
            .is_some_and(|state| matches!(state.ground_state,
                diffuse_scene::physics::character_controller::CharacterGroundState::OnGround |
                diffuse_scene::physics::character_controller::CharacterGroundState::OnSteepGround))
    })
}
extern "C" fn character_ground_state(instance: *mut c_void) -> u8 {
    with_current_context(instance, 0xff, |context| {
        context
            .character_state()
            .map(|state| state.ground_state.raw_value())
            .unwrap_or(0xff)
    })
}
extern "C" fn character_velocity(instance: *mut c_void, out: *mut [f32; 3]) {
    if out.is_null() {
        return;
    }
    let velocity = with_current_context(instance, [0.0; 3], |context| {
        context
            .character_state()
            .map(|state| {
                [
                    state.linear_velocity.x,
                    state.linear_velocity.y,
                    state.linear_velocity.z,
                ]
            })
            .unwrap_or([0.0; 3])
    });
    // SAFETY: the ABI caller supplies a writable three-lane output range for this call.
    unsafe {
        out.write(velocity);
    }
}
