//! Safe wrapper over the [`HostApi`] table.
//!
//! Swift scripts used `ScriptContext` directly; Rust scripts get this struct,
//! which holds the opaque handle and forwards to the table. Every method keeps
//! the Swift fallback: a missing entry behaves like the Swift bridge's
//! `guard let ctx ... else { return 0 }` paths.

use core::ffi::{CStr, c_void};
use core::marker::PhantomData;

use crate::abi::{ABI_VERSION, Bytes, CharacterStance, GroundState, HostApi, Slice, Transform3};

/// The handle a script receives in its lifecycle callbacks.
pub struct ScriptContext {
    host: HostApi,
    instance: *mut c_void,
    // The host guarantees the table outlives every callback.
    _not_send: PhantomData<*mut ()>,
}

impl ScriptContext {
    /// Wraps a host table. The caller guarantees `host.instance` (when non-null)
    /// stays alive for this context's lifetime.
    #[inline]
    pub fn new(host: HostApi) -> Self {
        let instance = host.instance;
        ScriptContext {
            host,
            instance,
            _not_send: PhantomData,
        }
    }

    /// The ABI version the host advertised.
    #[inline]
    pub fn abi_version(&self) -> u32 {
        self.host.abi_version
    }

    /// True when the host and this crate agree on the ABI.
    #[inline]
    pub fn is_compatible(&self) -> bool {
        self.host.abi_version == ABI_VERSION
    }

    #[inline]
    fn instance(&self) -> *mut c_void {
        self.instance
    }

    fn slice(value: &str) -> Slice {
        Slice {
            ptr: value.as_ptr(),
            len: value.len(),
        }
    }

    /// Copies host-owned bytes and releases them through the table.
    fn take_bytes(&self, bytes: Bytes) -> String {
        let text = String::from_utf8_lossy(bytes.as_slice()).into_owned();
        if bytes.owned
            && let Some(free) = self.host.free
        {
            free(bytes);
        }
        text
    }

    // ---- timing -----------------------------------------------------------

    /// `ScriptContext.deltaTime`.
    pub fn delta_time(&self) -> f64 {
        match self.host.delta_time {
            Some(delta_time) => delta_time(self.instance()),
            None => 0.0,
        }
    }

    // ---- input ------------------------------------------------------------

    /// `cove_input_axis`.
    pub fn input_axis(&self, name: &str) -> f32 {
        match self.host.input_axis {
            Some(axis) => axis(self.instance(), Self::slice(name)),
            None => 0.0,
        }
    }

    /// `cove_input_held`.
    pub fn input_held(&self, name: &str) -> bool {
        match self.host.input_held {
            Some(held) => held(self.instance(), Self::slice(name)),
            None => false,
        }
    }

    /// `cove_input_just_pressed`.
    pub fn input_just_pressed(&self, name: &str) -> bool {
        match self.host.input_just_pressed {
            Some(pressed) => pressed(self.instance(), Self::slice(name)),
            None => false,
        }
    }

    /// `cove_input_just_released`.
    pub fn input_just_released(&self, name: &str) -> bool {
        match self.host.input_just_released {
            Some(released) => released(self.instance(), Self::slice(name)),
            None => false,
        }
    }

    // ---- identity ---------------------------------------------------------

    /// `ScriptContext.entity`.
    pub fn entity(&self) -> u64 {
        match self.host.entity {
            Some(entity) => entity(self.instance()),
            None => 0,
        }
    }

    /// `ScriptContext.isAlive`.
    pub fn is_alive(&self, entity: u64) -> bool {
        match self.host.entity_is_alive {
            Some(is_alive) => is_alive(self.instance(), entity),
            None => false,
        }
    }

    /// `ScriptContext.contains(_:)`.
    #[inline]
    pub fn contains(&self, entity: u64) -> bool {
        self.is_alive(entity)
    }

    // ---- entity lifecycle -------------------------------------------------

    /// `ScriptContext.createEntity(named:parent:)`; `None` means creation failed.
    pub fn create_entity(&self, name: Option<&str>, parent: Option<u64>) -> Option<u64> {
        let create = self.host.create_entity?;
        let name_slice = match name {
            Some(value) => Self::slice(value),
            None => Slice::EMPTY,
        };
        let (parent_value, has_parent) = match parent {
            Some(value) => (value, true),
            None => (0, false),
        };
        let entity = create(self.instance(), name_slice, parent_value, has_parent);
        if entity == 0 { None } else { Some(entity) }
    }

    /// `ScriptContext.destroyEntity(_:)`.
    pub fn destroy_entity(&self, entity: u64) -> bool {
        match self.host.destroy_entity {
            Some(destroy) => destroy(self.instance(), entity),
            None => false,
        }
    }

    /// `ScriptContext.destroySelf()`.
    #[inline]
    pub fn destroy_self(&self) -> bool {
        let entity = self.entity();
        self.destroy_entity(entity)
    }

    /// `ScriptContext.setParent(_:for:)`.
    pub fn set_parent(&self, child: u64, parent: Option<u64>) -> bool {
        let set_parent = match self.host.set_parent {
            Some(set_parent) => set_parent,
            None => return false,
        };
        let (parent_value, has_parent) = match parent {
            Some(value) => (value, true),
            None => (0, false),
        };
        set_parent(self.instance(), child, parent_value, has_parent)
    }

    /// `ScriptContext.parent(of:)`.
    pub fn parent(&self, entity: u64) -> Option<u64> {
        let parent_of = self.host.parent_of?;
        let mut out: u64 = 0;
        if parent_of(self.instance(), entity, &mut out) {
            Some(out)
        } else {
            None
        }
    }

    /// `ScriptContext.entity(named:)`.
    pub fn entity_named(&self, name: &str) -> Option<u64> {
        let entity_named = self.host.entity_named?;
        let entity = entity_named(self.instance(), Self::slice(name));
        if entity == 0 { None } else { Some(entity) }
    }

    // ---- transforms -------------------------------------------------------

    /// `ScriptContext.localTransform`.
    pub fn local_transform(&self) -> Option<Transform3> {
        self.host
            .local_transform
            .map(|local_transform| local_transform(self.instance()))
    }

    /// `ScriptContext.localTransform(of:)`.
    pub fn local_transform_of(&self, entity: u64) -> Option<Transform3> {
        let local_transform_of = self.host.local_transform_of?;
        let mut out = Transform3::default();
        if local_transform_of(self.instance(), entity, &mut out) {
            Some(out)
        } else {
            None
        }
    }

    /// `ScriptContext.worldTransform`.
    pub fn world_transform(&self) -> Option<Transform3> {
        self.host
            .world_transform
            .map(|world_transform| world_transform(self.instance()))
    }

    /// `ScriptContext.worldTransform(of:)`.
    pub fn world_transform_of(&self, entity: u64) -> Option<Transform3> {
        let world_transform_of = self.host.world_transform_of?;
        let mut out = Transform3::default();
        if world_transform_of(self.instance(), entity, &mut out) {
            Some(out)
        } else {
            None
        }
    }

    /// `ScriptContext.setLocalTransform(_:)`.
    pub fn set_local_transform(&self, value: Transform3) -> bool {
        match self.host.set_local_transform {
            Some(set_local_transform) => set_local_transform(self.instance(), value),
            None => false,
        }
    }

    /// `ScriptContext.setLocalTransform(_:for:)`.
    pub fn set_local_transform_for(&self, value: Transform3, entity: u64) -> bool {
        match self.host.set_local_transform_for {
            Some(set_local_transform_for) => {
                set_local_transform_for(self.instance(), value, entity)
            }
            None => false,
        }
    }

    // ---- components -------------------------------------------------------

    /// `ScriptContext.component(_:)` — component JSON, or `None` when absent.
    pub fn component_json(&self, entity: u64, type_name: &str) -> Option<String> {
        let get_component = self.host.get_component?;
        let bytes = get_component(self.instance(), entity, Self::slice(type_name));
        if bytes.len == 0 {
            None
        } else {
            Some(self.take_bytes(bytes))
        }
    }

    /// `ScriptContext.hasComponent(_:)`.
    pub fn has_component(&self, entity: u64, type_name: &str) -> bool {
        match self.host.has_component {
            Some(has_component) => has_component(self.instance(), entity, Self::slice(type_name)),
            None => false,
        }
    }

    /// `ScriptContext.setComponent(_:)` from component JSON.
    pub fn set_component_json(&self, entity: u64, type_name: &str, json: &str) -> bool {
        match self.host.set_component {
            Some(set_component) => set_component(
                self.instance(),
                entity,
                Self::slice(type_name),
                Self::slice(json),
            ),
            None => false,
        }
    }

    /// `ScriptContext.removeComponent(_:)`.
    pub fn remove_component(&self, entity: u64, type_name: &str) -> bool {
        match self.host.remove_component {
            Some(remove_component) => {
                remove_component(self.instance(), entity, Self::slice(type_name))
            }
            None => false,
        }
    }

    // ---- parameters -------------------------------------------------------

    /// The binding's parameter JSON for this invocation; `"{}"` like Swift's default.
    pub fn parameters_json(&self) -> String {
        match self.host.parameters_json {
            Some(parameters_json) => self.take_bytes(parameters_json(self.instance())),
            None => "{}".to_string(),
        }
    }

    /// `ScriptContext.floatParameter(_:)`.
    pub fn float_parameter(&self, name: &str) -> Option<f32> {
        let float_parameter = self.host.float_parameter?;
        let mut out: f32 = 0.0;
        if float_parameter(self.instance(), Self::slice(name), &mut out) {
            Some(out)
        } else {
            None
        }
    }

    /// `ScriptContext.doubleParameter(_:)`.
    pub fn double_parameter(&self, name: &str) -> Option<f64> {
        let double_parameter = self.host.double_parameter?;
        let mut out: f64 = 0.0;
        if double_parameter(self.instance(), Self::slice(name), &mut out) {
            Some(out)
        } else {
            None
        }
    }

    /// `ScriptContext.stringParameter(_:)`.
    pub fn string_parameter(&self, name: &str) -> Option<String> {
        let string_parameter = self.host.string_parameter?;
        let bytes = string_parameter(self.instance(), Self::slice(name));
        if bytes.len == 0 {
            None
        } else {
            Some(self.take_bytes(bytes))
        }
    }

    /// `ScriptContext.vector3Parameter(_:)`.
    pub fn vector3_parameter(&self, name: &str) -> Option<[f32; 4]> {
        let vector3_parameter = self.host.vector3_parameter?;
        let mut out = [0.0f32; 4];
        if vector3_parameter(self.instance(), Self::slice(name), &mut out) {
            Some(out)
        } else {
            None
        }
    }

    /// `ScriptContext.entityParameter(_:)`.
    pub fn entity_parameter(&self, name: &str) -> Option<u64> {
        let entity_parameter = self.host.entity_parameter?;
        let mut out: u64 = 0;
        if entity_parameter(self.instance(), Self::slice(name), &mut out) {
            Some(out)
        } else {
            None
        }
    }

    // ---- resources --------------------------------------------------------

    /// `ScriptContext.resource(_:)` — resource JSON, or `None` when absent.
    pub fn resource_json(&self, type_name: &str) -> Option<String> {
        let get_resource = self.host.get_resource?;
        let bytes = get_resource(self.instance(), Self::slice(type_name));
        if bytes.len == 0 {
            None
        } else {
            Some(self.take_bytes(bytes))
        }
    }

    /// `ScriptContext.setResource(_:)` from resource JSON.
    pub fn set_resource_json(&self, type_name: &str, json: &str) -> bool {
        match self.host.set_resource {
            Some(set_resource) => {
                set_resource(self.instance(), Self::slice(type_name), Self::slice(json))
            }
            None => false,
        }
    }

    /// `ScriptContext.removeResource(_:)`.
    pub fn remove_resource(&self, type_name: &str) -> bool {
        match self.host.remove_resource {
            Some(remove_resource) => remove_resource(self.instance(), Self::slice(type_name)),
            None => false,
        }
    }

    // ---- UI and state -----------------------------------------------------

    /// `ScriptContext.drawUI { canvas.label(...) }`.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_label(&self, text: &str, x: f32, y: f32, font_size: f32, color: [f32; 4]) {
        if let Some(draw_label) = self.host.draw_label {
            draw_label(self.instance(), Self::slice(text), x, y, font_size, color);
        }
    }

    /// `ScriptContext.drawUI { canvas.rect(...) }`.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_rect(&self, x: f32, y: f32, w: f32, h: f32, corner_radius: f32, color: [f32; 4]) {
        if let Some(draw_rect) = self.host.draw_rect {
            draw_rect(self.instance(), x, y, w, h, corner_radius, color);
        }
    }

    /// `ScriptContext.drawUI { canvas.progressBar(...) }`.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_progress_bar(
        &self,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        value: f32,
        max_value: f32,
        corner_radius: f32,
        fill_color: [f32; 4],
        bg_color: [f32; 4],
    ) {
        if let Some(draw_progress_bar) = self.host.draw_progress_bar {
            draw_progress_bar(
                self.instance(),
                x,
                y,
                w,
                h,
                value,
                max_value,
                corner_radius,
                fill_color,
                bg_color,
            );
        }
    }

    /// `ScriptContext.reportState`.
    pub fn report_state(&self, json: &str) {
        if let Some(report_state) = self.host.report_state {
            report_state(self.instance(), Self::slice(json));
        }
    }

    // ---- character controller --------------------------------------------

    /// `cove_submit_character_command`.
    pub fn submit_character_command(
        &self,
        velocity: [f32; 3],
        jump: bool,
        jump_speed: f32,
        stance: CharacterStance,
    ) {
        if let Some(submit) = self.host.submit_character_command {
            submit(
                self.instance(),
                velocity[0],
                velocity[1],
                velocity[2],
                jump,
                jump_speed,
                stance as u8,
            );
        }
    }

    /// `cove_character_is_grounded`.
    pub fn character_is_grounded(&self) -> bool {
        match self.host.character_is_grounded {
            Some(is_grounded) => is_grounded(self.instance()),
            None => false,
        }
    }

    /// `cove_character_ground_state`.
    pub fn character_ground_state(&self) -> GroundState {
        match self.host.character_ground_state {
            Some(ground_state) => GroundState::from_raw(ground_state(self.instance())),
            None => GroundState::Unavailable,
        }
    }

    /// `cove_character_velocity`.
    pub fn character_velocity(&self) -> [f32; 3] {
        match self.host.character_velocity {
            Some(velocity) => {
                let mut out = [0.0f32; 3];
                velocity(self.instance(), &mut out);
                out
            }
            None => [0.0, 0.0, 0.0],
        }
    }
}

/// Reads a NUL-terminated C string, mirroring Swift's `String(cString:)`.
///
/// # Safety
///
/// `ptr` must be a valid NUL-terminated string, or null.
pub unsafe fn c_string_to_owned(ptr: *const core::ffi::c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees a valid NUL-terminated string.
    let c_str = unsafe { CStr::from_ptr(ptr) };
    c_str.to_str().ok().map(str::to_string)
}
