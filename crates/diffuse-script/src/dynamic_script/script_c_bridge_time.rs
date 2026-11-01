use super::script_c_bridge_context::with_current_context;
use diffuse_script_api::abi::HostApi;
use std::ffi::c_void;

pub(crate) fn install(table: &mut HostApi) {
    table.delta_time = Some(delta_time);
}
extern "C" fn delta_time(instance: *mut c_void) -> f64 {
    with_current_context(instance, 0.0, |context| context.delta_time)
}
/// The original cove_delta_time entry rounds the ScriptContext Double to Float.
pub extern "C" fn cove_delta_time(instance: *mut c_void) -> f32 {
    delta_time(instance) as f32
}
