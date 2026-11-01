//! Safe wrapper over the [`HostApi`] table.
//!
//! Swift scripts used `ScriptContext` directly; Rust scripts get this struct,
//! which holds the opaque handle and forwards to the table. Every method keeps
//! the Swift fallback: a missing entry behaves like the Swift bridge's
//! `guard let ctx ... else { return 0 }` paths.

use core::ffi::{CStr, c_void};
use core::marker::PhantomData;

use crate::abi::{
    ABI_VERSION, Bytes, CharacterStance, Color4, GroundState, HostApi, Slice, Transform3,
};

/// The handle a script receives in its lifecycle callbacks.
pub struct ScriptContext {
    host: HostApi,
    instance: *mut c_void,
    // The host guarantees the table outlives every callback.
    _not_send: PhantomData<*mut ()>,
}

impl ScriptContext {
    /// Wraps a host table for one callback.
    ///
    /// # Safety
    /// Every populated function and the opaque instance must remain valid for
    /// this context's lifetime. Returned byte ranges must satisfy the ABI contract.
    #[inline]
    pub unsafe fn new(host: HostApi) -> Self {
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
        // SAFETY: the host contract guarantees a live initialized range until free.
        let text = String::from_utf8_lossy(unsafe { bytes.as_slice() }).into_owned();
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

    pub fn is_alive(&self) -> bool { self.contains(self.entity()) }
    pub fn contains(&self, entity: u64) -> bool { self.host.entity_is_alive.is_some_and(|f| f(self.instance(), entity)) }
    pub fn create_entity(&self, name: Option<&str>, transform: Transform3) -> Option<u64> {
        let mut entity = 0;
        let success = (self.host.create_entity?)(self.instance(), Self::slice(name.unwrap_or("")), name.is_some(), transform, &mut entity);
        success.then_some(entity)
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

    pub fn entity_named(&self, name: &str) -> Option<u64> {
        let mut entity = 0;
        (self.host.entity_named?)(self.instance(), Self::slice(name), &mut entity).then_some(entity)
    }
    pub fn local_transform(&self) -> Option<Transform3> {
        let mut value = Transform3::default();
        (self.host.local_transform?)(self.instance(), &mut value).then_some(value)
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

    pub fn world_transform(&self) -> Option<Transform3> {
        let mut value = Transform3::default();
        (self.host.world_transform?)(self.instance(), &mut value).then_some(value)
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
        if bytes.ptr.is_null() {
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

    pub fn remove_component(&self, entity: u64, type_name: &str) -> Option<String> {
        let bytes = (self.host.remove_component?)(self.instance(), entity, Self::slice(type_name));
        if bytes.ptr.is_null() { None } else { Some(self.take_bytes(bytes)) }
    }
    pub fn update_component_json(&self, entity: u64, name: &str, body: impl FnOnce(&mut crate::authoring::json::JsonValue)) -> bool {
        let Some(text) = self.component_json(entity, name) else { return false; };
        let Some(mut value) = crate::authoring::json::parse(&text) else { return false; };
        body(&mut value);
        value.try_to_json().is_some_and(|text| self.set_component_json(entity, name, &text))
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
        if bytes.ptr.is_null() {
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
        if bytes.ptr.is_null() {
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

    pub fn remove_resource(&self, type_name: &str) -> Option<String> {
        let bytes = (self.host.remove_resource?)(self.instance(), Self::slice(type_name));
        if bytes.ptr.is_null() { None } else { Some(self.take_bytes(bytes)) }
    }
    pub fn update_resource_json(&self, name: &str, body: impl FnOnce(&mut crate::authoring::json::JsonValue)) -> bool {
        let Some(text) = self.resource_json(name) else { return false; };
        let Some(mut value) = crate::authoring::json::parse(&text) else { return false; };
        body(&mut value);
        value.try_to_json().is_some_and(|text| self.set_resource_json(name, &text))
    }

    // ---- UI and state -----------------------------------------------------

    /// `ScriptContext.drawUI { canvas.label(...) }`.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_label(&self, text: &str, x: f32, y: f32, font_size: f32, color: [f32; 4]) {
        if let Some(draw_label) = self.host.draw_label {
            draw_label(
                self.instance(),
                Self::slice(text),
                x,
                y,
                font_size,
                Color4::new(color),
            );
        }
    }

    /// `ScriptContext.drawUI { canvas.rect(...) }`.
    #[allow(clippy::too_many_arguments)]
    pub fn draw_rect(&self, x: f32, y: f32, w: f32, h: f32, corner_radius: f32, color: [f32; 4]) {
        if let Some(draw_rect) = self.host.draw_rect {
            draw_rect(
                self.instance(),
                x,
                y,
                w,
                h,
                corner_radius,
                Color4::new(color),
            );
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
                Color4::new(fill_color),
                Color4::new(bg_color),
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
    pub fn entities(&self) -> Vec<u64> { self.host.entities.map(|f| self.entity_list(f(self.instance()))).unwrap_or_default() }
    pub fn children(&self, entity: u64) -> Vec<u64> { self.host.children.map(|f| self.entity_list(f(self.instance(), entity))).unwrap_or_default() }
    fn entity_list(&self, bytes: Bytes) -> Vec<u64> {
        match crate::authoring::json::parse(&self.take_bytes(bytes)) {
            Some(crate::authoring::json::JsonValue::Array(values)) => values.iter().filter_map(crate::authoring::json::JsonValue::as_u64).collect(),
            _ => Vec::new(),
        }
    }
    pub fn translate(&self, entity: u64, delta: [f32;3]) -> bool { self.host.translate.is_some_and(|f| f(self.instance(), entity, delta[0], delta[1], delta[2])) }
    pub fn instantiate(&self, document: &str, parent: Option<u64>, transform: Option<Transform3>) -> Option<u64> {
        let mut entity = 0;
        (self.host.instantiate?)(self.instance(), Self::slice(document), parent.unwrap_or(0), parent.is_some(), transform.unwrap_or_default(), transform.is_some(), &mut entity).then_some(entity)
    }
    pub fn parameters(&self) -> crate::authoring::json::JsonObject {
        self.host.resolved_parameters_json.map(|f| crate::authoring::json::parse_object(&self.take_bytes(f(self.instance())))).unwrap_or_default()
    }
    pub fn input(&self) -> crate::authoring::json::JsonObject {
        self.host.input_frame.map(|f| crate::authoring::json::parse_object(&self.take_bytes(f(self.instance())))).unwrap_or_default()
    }
    pub fn trigger_events(&self) -> crate::authoring::json::JsonObject {
        self.host.trigger_events.map(|f| crate::authoring::json::parse_object(&self.take_bytes(f(self.instance())))).unwrap_or_default()
    }
    pub fn triggers_entered(&self) -> Vec<crate::authoring::json::JsonValue> { self.own_trigger_events("enters") }
    pub fn triggers_exited(&self) -> Vec<crate::authoring::json::JsonValue> { self.own_trigger_events("exits") }
    fn own_trigger_events(&self, key: &str) -> Vec<crate::authoring::json::JsonValue> {
        self.trigger_events().get(key).and_then(|value| value.as_array()).unwrap_or_default().iter()
            .filter(|value| value.as_object().and_then(|value| value.get("triggerEntity")).and_then(|value| value.as_u64()) == Some(self.entity())).cloned().collect()
    }
    pub fn did_trigger_enter(&self, other: u64) -> bool { self.triggers_entered().iter().any(|value| value.as_object().and_then(|value| value.get("otherEntity")).and_then(|value| value.as_u64()) == Some(other)) }
    pub fn did_trigger_exit(&self, other: u64) -> bool { self.triggers_exited().iter().any(|value| value.as_object().and_then(|value| value.get("otherEntity")).and_then(|value| value.as_u64()) == Some(other)) }
    pub fn character_state(&self) -> Option<crate::authoring::json::JsonValue> {
        let bytes = (self.host.character_state?)(self.instance());
        if bytes.ptr.is_null() { None } else { crate::authoring::json::parse(&self.take_bytes(bytes)) }
    }
    pub fn submit_vehicle_command(&self, json: &str) -> bool { self.host.submit_vehicle_command.is_some_and(|f| f(self.instance(), Self::slice(json))) }
    fn query(&self, function: Option<extern "C" fn(*mut c_void, Slice, Slice) -> Bytes>, query: &str, filter: &str) -> Option<crate::authoring::json::JsonValue> {
        let bytes = function?(self.instance(), Self::slice(query), Self::slice(filter));
        if bytes.ptr.is_null() { None } else { crate::authoring::json::parse(&self.take_bytes(bytes)) }
    }
    pub fn physics_raycast(&self, query: &str, filter: &str) -> Option<crate::authoring::json::JsonValue> { self.query(self.host.physics_raycast, query, filter) }
    pub fn physics_overlap_aabb(&self, query: &str, filter: &str) -> Option<crate::authoring::json::JsonValue> { self.query(self.host.physics_overlap_aabb, query, filter) }
    pub fn physics_overlap_shape(&self, query: &str, filter: &str) -> Option<crate::authoring::json::JsonValue> { self.query(self.host.physics_overlap_shape, query, filter) }
    pub fn physics_sweep_aabb(&self, query: &str, filter: &str) -> Option<crate::authoring::json::JsonValue> { self.query(self.host.physics_sweep_aabb, query, filter) }
    pub fn physics_sweep_shape(&self, query: &str, filter: &str) -> Option<crate::authoring::json::JsonValue> { self.query(self.host.physics_sweep_shape, query, filter) }
    pub fn raycast(&self, origin: [f32;3], direction: [f32;3], max_distance: f32, filter: &str) -> Option<crate::authoring::json::JsonValue> {
        use crate::authoring::json::{JsonValue as V, JsonObject};
        let vector = |v: [f32;3]| V::Array(v.into_iter().map(V::Float).collect());
        let query = V::Object(JsonObject::from([("origin".into(), vector(origin)), ("direction".into(), vector(direction)), ("maxDistance".into(), V::Float(max_distance))])).try_to_json()?;
        self.physics_raycast(&query, filter)
    }
    pub fn overlap(&self, min: [f32;3], max: [f32;3], filter: &str) -> Option<crate::authoring::json::JsonValue> {
        self.physics_overlap_aabb(&bounds_query(min, max, None)?, filter)
    }
    pub fn sweep(&self, min: [f32;3], max: [f32;3], translation: [f32;3], filter: &str) -> Option<crate::authoring::json::JsonValue> {
        self.physics_sweep_aabb(&bounds_query(min, max, Some(translation))?, filter)
    }
    pub fn draw_ui(&self, body: impl FnOnce(&Self)) { if self.host.canvas_exists.is_some_and(|f| f(self.instance())) { body(self); } }
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

fn bounds_query(min: [f32;3], max: [f32;3], translation: Option<[f32;3]>) -> Option<String> {
    use crate::authoring::json::{JsonValue as V, JsonObject};
    let vector = |v: [f32;3]| V::Array(v.into_iter().map(V::Float).collect());
    let mut fields = JsonObject::from([("bounds".into(), V::Object(JsonObject::from([("min".into(), vector(min)), ("max".into(), vector(max))])))]);
    if let Some(translation) = translation { fields.insert("translation".into(), vector(translation)); }
    V::Object(fields).try_to_json()
}
