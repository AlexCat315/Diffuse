use super::script_c_bridge_context::{string_from, with_current_context};
use diffuse_script_api::abi::{HostApi, Slice};
use std::ffi::c_void;

pub(crate) fn install(table: &mut HostApi) {
    table.input_axis = Some(input_axis);
    table.input_held = Some(input_held);
    table.input_just_pressed = Some(input_just_pressed);
    table.input_just_released = Some(input_just_released);
}
extern "C" fn input_axis(instance: *mut c_void, name: Slice) -> f32 {
    with_current_context(instance, 0.0, |context| {
        string_from(name)
            .map(|name| context.input().axis(&name))
            .unwrap_or(0.0)
    })
}
extern "C" fn input_held(instance: *mut c_void, name: Slice) -> bool {
    with_current_context(instance, false, |context| {
        string_from(name).is_some_and(|name| context.input().is_held(&name))
    })
}
extern "C" fn input_just_pressed(instance: *mut c_void, name: Slice) -> bool {
    with_current_context(instance, false, |context| {
        string_from(name).is_some_and(|name| context.input().is_just_pressed(&name))
    })
}
extern "C" fn input_just_released(instance: *mut c_void, name: Slice) -> bool {
    with_current_context(instance, false, |context| {
        string_from(name).is_some_and(|name| context.input().is_just_released(&name))
    })
}
