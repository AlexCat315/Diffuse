//! Scoped context dispatch and stable per-instance HostApi state (D1).

use crate::core::script_context::ScriptContext;
use crate::core::script_definition::JsonValue;
use crate::interop::component_registry_script_codec::ComponentRegistryScriptCodec;
use diffuse_kernel::in_game_canvas::InGameCanvasCommand;
use diffuse_kernel::in_game_canvas::{InGameCanvas, InGameUIColor};
use diffuse_kernel::input_event::{GamepadAxis, GamepadButton, MouseButton};
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_scene::components::core::registry::ComponentSchema;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::input_action::{
    InputActionMap, InputBinding, InputFrameState, MouseMotionAxis, MouseWheelAxis,
};
use diffuse_scene::physics::character_controller::{
    CharacterGroundState, CharacterStance, CharacterState, CharacterStateFrameResource,
};
use diffuse_scene::physics::collider::SpatialAABB;
use diffuse_scene::physics::queries::physics_query_types::*;
use diffuse_scene::physics::queries::trigger_detection::{
    TriggerEvent, TriggerEventKind, TriggerFrameResource,
};
use diffuse_scene::physics::vehicles::vehicle_state::{
    VehicleCommand, VehicleCommandFrameResource,
};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::runtime_world::RuntimeWorld;
use diffuse_scene::scene_graph::prefab::Prefab;
use diffuse_script_api::abi::{Bytes, Color4, HostApi, Slice, Transform3, slice_of};
use serde::{Deserialize, Serialize};
use std::{
    cell::{Cell, RefCell},
    collections::{BTreeMap, BTreeSet},
    ffi::c_void,
    panic::AssertUnwindSafe,
    rc::Rc,
    sync::{Arc, Mutex, OnceLock},
};

/// Kept by the loader until the SDK instance and all its callbacks have been destroyed.
#[derive(Default)]
pub(crate) struct ScriptHostInstance {
    errors: Mutex<Vec<String>>,
}
impl ScriptHostInstance {
    pub(crate) fn take_errors(&self) -> Vec<String> {
        std::mem::take(
            &mut *self
                .errors
                .lock()
                .unwrap_or_else(|error| error.into_inner()),
        )
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScriptErrorState {
    pub entities: BTreeMap<EntityID, Vec<String>>,
}

struct Invocation {
    host: *mut c_void,
    context: *mut c_void,
    borrowed: Cell<bool>,
}
thread_local! { static INVOCATIONS: RefCell<Vec<Rc<Invocation>>> = const { RefCell::new(Vec::new()) }; }
struct InvocationScope(Rc<Invocation>);
impl Drop for InvocationScope {
    fn drop(&mut self) {
        INVOCATIONS.with(|frames| {
            let mut frames = frames.borrow_mut();
            if frames
                .last()
                .is_some_and(|frame| Rc::ptr_eq(frame, &self.0))
            {
                frames.pop();
            }
        });
    }
}
struct ContextBorrow(Rc<Invocation>);
impl Drop for ContextBorrow {
    fn drop(&mut self) {
        self.0.borrowed.set(false);
    }
}

/// No native context address is retained after body returns, including during unwinding.
pub(crate) fn with_host_context<R>(
    host: &Arc<ScriptHostInstance>,
    context: &mut ScriptContext<'_, '_>,
    body: impl FnOnce(&HostApi) -> R,
) -> R {
    if context
        .phase_context
        .component_registry()
        .get("script")
        .is_none()
    {
        let mut registry = context.phase_context.component_registry().clone();
        registry.register_default_script_codec();
        context.phase_context.set_component_registry(registry);
    }
    let table = host_api(host);
    let frame = Rc::new(Invocation {
        host: table.instance,
        context: (context as *mut ScriptContext<'_, '_>).cast(),
        borrowed: Cell::new(false),
    });
    INVOCATIONS.with(|frames| frames.borrow_mut().push(frame.clone()));
    let scope = InvocationScope(frame);
    let result = body(&table);
    drop(scope);
    let errors = host.take_errors();
    if !errors.is_empty() {
        let mut state = context.resource::<ScriptErrorState>().unwrap_or_default();
        state
            .entities
            .entry(context.entity)
            .or_default()
            .extend(errors);
        context.set_resource(state);
    }
    result
}

/// Null, inactive, foreign-thread and reentrant handles preserve the Swift bridge fallback.
pub(crate) fn with_current_context<R>(
    host: *mut c_void,
    fallback: R,
    body: impl FnOnce(&mut ScriptContext<'_, '_>) -> R,
) -> R {
    let frame = INVOCATIONS.with(|frames| {
        frames
            .borrow()
            .last()
            .filter(|frame| frame.host == host && !frame.borrowed.get())
            .cloned()
    });
    let Some(frame) = frame else {
        return fallback;
    };
    frame.borrowed.set(true);
    let borrow = ContextBorrow(frame.clone());
    let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: with_host_context owns the exclusive context borrow until the frame is removed.
        // This pointer is accessed only on that same thread and ContextBorrow rejects aliasing
        // reentrancy. The closure cannot return a borrow of the erased context.
        let context = unsafe { &mut *frame.context.cast::<ScriptContext<'_, '_>>() };
        body(context)
    }));
    drop(borrow);
    match result {
        Ok(value) => value,
        Err(payload) => {
            let message = payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| {
                    payload
                        .downcast_ref::<&str>()
                        .map(|text| (*text).to_owned())
                })
                .unwrap_or_else(|| "HostApi callback panicked".into());
            std::mem::forget(payload);
            report_error(
                host,
                Slice {
                    ptr: message.as_ptr(),
                    len: message.len(),
                },
            );
            fallback
        }
    }
}

pub(crate) fn host_api(host: &Arc<ScriptHostInstance>) -> HostApi {
    let mut table = HostApi::empty();
    table.instance = Arc::as_ptr(host).cast_mut().cast();
    table.allocate = Some(allocate);
    table.free = Some(free);
    table.report_error = Some(report_error);
    table.entity = Some(entity);
    table.entity_is_alive = Some(entity_is_alive);
    table.create_entity = Some(create_entity);
    table.destroy_entity = Some(destroy_entity);
    table.set_parent = Some(set_parent);
    table.parent_of = Some(parent_of);
    table.entity_named = Some(entity_named);
    table.local_transform = Some(local_transform);
    table.local_transform_of = Some(local_transform_of);
    table.world_transform = Some(world_transform);
    table.world_transform_of = Some(world_transform_of);
    table.set_local_transform = Some(set_local_transform);
    table.set_local_transform_for = Some(set_local_transform_for);
    table.parameters_json = Some(parameters_json);
    table.float_parameter = Some(float_parameter);
    table.double_parameter = Some(double_parameter);
    table.string_parameter = Some(string_parameter);
    table.vector3_parameter = Some(vector3_parameter);
    table.entity_parameter = Some(entity_parameter);
    table.entities = Some(entities);
    table.children = Some(children);
    table.translate = Some(translate);
    table.instantiate = Some(instantiate);
    table.resolved_parameters_json = Some(resolved_parameters_json);
    table.canvas_exists = Some(canvas_exists);
    table.draw_label = Some(draw_label);
    table.draw_rect = Some(draw_rect);
    table.draw_progress_bar = Some(draw_progress_bar);
    table.report_state = Some(report_state);
    table.get_component = Some(get_component);
    table.has_component = Some(has_component);
    table.set_component = Some(set_component);
    table.remove_component = Some(remove_component);
    table.get_resource = Some(get_resource);
    table.set_resource = Some(set_resource);
    table.remove_resource = Some(remove_resource);
    table.input_frame = Some(input_frame);
    table.trigger_events = Some(trigger_events);
    table.character_state = Some(character_state);
    table.submit_vehicle_command = Some(submit_vehicle_command);
    table.physics_raycast = Some(physics_raycast);
    table.physics_overlap_aabb = Some(physics_overlap_aabb);
    table.physics_overlap_shape = Some(physics_overlap_shape);
    table.physics_sweep_aabb = Some(physics_sweep_aabb);
    table.physics_sweep_shape = Some(physics_sweep_shape);
    super::script_c_bridge_time::install(&mut table);
    super::script_c_bridge_input::install(&mut table);
    super::script_c_bridge_character::install(&mut table);
    table
}

pub(crate) fn string_from(slice: Slice) -> Option<String> {
    // SAFETY: ABI callers keep their UTF-8 range live for the callback.
    unsafe { slice.as_str() }.map(str::to_owned)
}

pub(crate) extern "C" fn allocate(length: usize) -> Bytes {
    match std::panic::catch_unwind(|| vec![0_u8; length].into_boxed_slice()) {
        Ok(bytes) => Bytes {
            ptr: Box::into_raw(bytes).cast(),
            len: length,
            owned: true,
        },
        Err(payload) => {
            std::mem::forget(payload);
            Bytes::EMPTY
        }
    }
}

pub(crate) extern "C" fn free(bytes: Bytes) {
    if bytes.owned && !bytes.ptr.is_null() {
        // SAFETY: callers transfer exactly one range created by this host's allocator.
        // Box<[u8]> retains its exact length, so no Vec capacity crosses the ABI.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len)) });
    }
}

pub(crate) extern "C" fn report_error(host: *mut c_void, message: Slice) {
    if host.is_null() {
        return;
    }
    let Some(message) = string_from(message) else {
        return;
    };
    // SAFETY: HostApi.instance is an Arc-backed ScriptHostInstance retained by the loader
    // through creation, every lifecycle callback and final SDK destruction.
    let host = unsafe { &*host.cast::<ScriptHostInstance>() };
    host.errors
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .push(message);
}

/// Allocate through the host so SDK strings, including empty strings, always
/// have matching ownership and never cross DLL allocators during release.
fn owned_bytes(value: &[u8]) -> Bytes {
    let bytes = allocate(value.len());
    if !bytes.ptr.is_null() && bytes.len == value.len() {
        // SAFETY: allocate returns a writable range of exactly this length;
        // the source is separately owned and lives through the copy.
        unsafe {
            std::ptr::copy_nonoverlapping(value.as_ptr(), bytes.ptr, value.len());
        }
    }
    bytes
}

/// Retain ownership until an edit completes, including native panic cleanup.
struct PendingHostBytes(Bytes);
impl PendingHostBytes {
    fn release(mut self) -> Bytes {
        std::mem::replace(&mut self.0, Bytes::EMPTY)
    }
}
impl Drop for PendingHostBytes {
    fn drop(&mut self) {
        free(self.0);
    }
}

fn encoded_bytes<T: serde::Serialize + ?Sized>(host: *mut c_void, value: &T) -> Bytes {
    match diffuse_assets::swift_json::to_compact(value) {
        Ok(text) => owned_bytes(text.as_bytes()),
        Err(error) => {
            report_error(host, slice_of(&error.to_string()));
            Bytes::EMPTY
        }
    }
}

fn write_output<T>(out: *mut T, value: T) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: each HostApi entry's caller supplies an aligned, writable output
    // for T, valid until the callback returns. No engine borrow escapes.
    unsafe {
        out.write(value);
    }
    true
}

fn from_abi(value: Transform3) -> LocalTransform {
    LocalTransform {
        matrix: Float4x4::from_columns(value.columns.map(|c| Float4::new(c[0], c[1], c[2], c[3]))),
    }
}
fn to_abi(matrix: Float4x4) -> Transform3 {
    Transform3::from_columns(matrix.columns.map(|c| [c.x, c.y, c.z, c.w]))
}
fn entity_id(raw: u64) -> EntityID {
    EntityID::from_raw_value(raw)
}

extern "C" fn entity(host: *mut c_void) -> u64 {
    with_current_context(host, 0, |context| context.entity.raw_value())
}
extern "C" fn entity_is_alive(host: *mut c_void, entity: u64) -> bool {
    with_current_context(host, false, |context| context.contains(entity_id(entity)))
}
extern "C" fn create_entity(
    host: *mut c_void,
    name: Slice,
    has_name: bool,
    transform: Transform3,
    out: *mut u64,
) -> bool {
    if out.is_null() {
        return false;
    }
    with_current_context(host, false, |context| {
        let name = if has_name {
            let Some(name) = string_from(name) else {
                return false;
            };
            Some(name)
        } else {
            None
        };
        write_output(
            out,
            context
                .create_entity(name.as_deref(), from_abi(transform))
                .raw_value(),
        )
    })
}
extern "C" fn destroy_entity(host: *mut c_void, entity: u64) -> bool {
    with_current_context(host, false, |context| {
        let entity = entity_id(entity);
        if !context.contains(entity) {
            return false;
        }
        context.destroy_entity(entity);
        true
    })
}
extern "C" fn set_parent(host: *mut c_void, child: u64, parent: u64, has_parent: bool) -> bool {
    with_current_context(host, false, |context| {
        context.set_parent_for(has_parent.then(|| entity_id(parent)), entity_id(child))
    })
}
extern "C" fn parent_of(host: *mut c_void, entity: u64, out: *mut u64) -> bool {
    with_current_context(host, false, |context| {
        context
            .parent_of(entity_id(entity))
            .is_some_and(|value| write_output(out, value.raw_value()))
    })
}
extern "C" fn entity_named(host: *mut c_void, name: Slice, out: *mut u64) -> bool {
    with_current_context(host, false, |context| {
        let Some(name) = string_from(name) else {
            return false;
        };
        context
            .entity_named(&name)
            .is_some_and(|value| write_output(out, value.raw_value()))
    })
}

fn get_transform(
    host: *mut c_void,
    entity: Option<EntityID>,
    world: bool,
    out: *mut Transform3,
) -> bool {
    with_current_context(host, false, |context| {
        let entity = entity.unwrap_or(context.entity);
        let matrix = if world {
            context.world_transform_of(entity).map(|value| value.matrix)
        } else {
            context.local_transform_of(entity).map(|value| value.matrix)
        };
        matrix.is_some_and(|value| write_output(out, to_abi(value)))
    })
}
extern "C" fn local_transform(host: *mut c_void, out: *mut Transform3) -> bool {
    get_transform(host, None, false, out)
}
extern "C" fn local_transform_of(host: *mut c_void, entity: u64, out: *mut Transform3) -> bool {
    get_transform(host, Some(entity_id(entity)), false, out)
}
extern "C" fn world_transform(host: *mut c_void, out: *mut Transform3) -> bool {
    get_transform(host, None, true, out)
}
extern "C" fn world_transform_of(host: *mut c_void, entity: u64, out: *mut Transform3) -> bool {
    get_transform(host, Some(entity_id(entity)), true, out)
}
extern "C" fn set_local_transform(host: *mut c_void, value: Transform3) -> bool {
    with_current_context(host, false, |context| {
        context.set_local_transform(from_abi(value))
    })
}
extern "C" fn set_local_transform_for(host: *mut c_void, value: Transform3, entity: u64) -> bool {
    with_current_context(host, false, |context| {
        context.set_local_transform_for(from_abi(value), entity_id(entity))
    })
}
extern "C" fn translate(host: *mut c_void, entity: u64, x: f32, y: f32, z: f32) -> bool {
    with_current_context(host, false, |context| {
        context.translate_for(Float3::new(x, y, z), entity_id(entity))
    })
}
extern "C" fn entities(host: *mut c_void) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| {
        encoded_bytes(
            host,
            &context
                .entities()
                .iter()
                .map(EntityID::raw_value)
                .collect::<Vec<_>>(),
        )
    })
}
extern "C" fn children(host: *mut c_void, entity: u64) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| {
        encoded_bytes(
            host,
            &context
                .children_of(entity_id(entity))
                .iter()
                .map(EntityID::raw_value)
                .collect::<Vec<_>>(),
        )
    })
}
extern "C" fn instantiate(
    host: *mut c_void,
    document: Slice,
    parent: u64,
    has_parent: bool,
    transform: Transform3,
    has_transform: bool,
    out: *mut u64,
) -> bool {
    if out.is_null() {
        return false;
    }
    with_current_context(host, false, |context| {
        let Some(document) = string_from(document) else {
            return false;
        };
        match context.instantiate(
            &Prefab::new(document),
            has_parent.then(|| entity_id(parent)),
            has_transform.then(|| from_abi(transform)),
        ) {
            Ok(Some(entity)) => write_output(out, entity.raw_value()),
            Ok(None) => false,
            Err(error) => {
                report_error(host, slice_of(&error.to_string()));
                false
            }
        }
    })
}

extern "C" fn parameters_json(host: *mut c_void) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| {
        owned_bytes(context.parameters_json.as_bytes())
    })
}
extern "C" fn resolved_parameters_json(host: *mut c_void) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| {
        match JsonValue::Object(context.parameters().clone()).try_to_json() {
            Some(text) => owned_bytes(text.as_bytes()),
            None => {
                report_error(
                    host,
                    slice_of("Script parameters contain non-finite values."),
                );
                Bytes::EMPTY
            }
        }
    })
}
extern "C" fn float_parameter(host: *mut c_void, name: Slice, out: *mut f32) -> bool {
    with_current_context(host, false, |context| {
        string_from(name)
            .and_then(|name| context.float_parameter(&name))
            .is_some_and(|value| write_output(out, value))
    })
}
extern "C" fn double_parameter(host: *mut c_void, name: Slice, out: *mut f64) -> bool {
    with_current_context(host, false, |context| {
        string_from(name)
            .and_then(|name| context.double_parameter(&name))
            .is_some_and(|value| write_output(out, value))
    })
}
extern "C" fn string_parameter(host: *mut c_void, name: Slice) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| {
        string_from(name)
            .and_then(|name| {
                context
                    .string_parameter(&name)
                    .map(|value| owned_bytes(value.as_bytes()))
            })
            .unwrap_or(Bytes::EMPTY)
    })
}
extern "C" fn vector3_parameter(host: *mut c_void, name: Slice, out: *mut [f32; 4]) -> bool {
    with_current_context(host, false, |context| {
        string_from(name)
            .and_then(|name| context.vector3_parameter(&name))
            .is_some_and(|value| write_output(out, [value.x, value.y, value.z, 0.0]))
    })
}
extern "C" fn entity_parameter(host: *mut c_void, name: Slice, out: *mut u64) -> bool {
    with_current_context(host, false, |context| {
        string_from(name)
            .and_then(|name| context.entity_parameter(&name))
            .is_some_and(|value| write_output(out, value.raw_value()))
    })
}

fn color(value: Color4) -> InGameUIColor {
    InGameUIColor::new(value.rgba[0], value.rgba[1], value.rgba[2], value.rgba[3])
}
extern "C" fn canvas_exists(host: *mut c_void) -> bool {
    with_current_context(host, false, |context| {
        context.resource::<InGameCanvas>().is_some()
    })
}
extern "C" fn draw_label(
    host: *mut c_void,
    text: Slice,
    x: f32,
    y: f32,
    font_size: f32,
    tint: Color4,
) {
    with_current_context(host, (), |context| {
        if let Some(text) = string_from(text) {
            context.draw_ui(|canvas| canvas.label_styled(text, x, y, font_size, color(tint)));
        }
    });
}
extern "C" fn draw_rect(
    host: *mut c_void,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    corner_radius: f32,
    tint: Color4,
) {
    with_current_context(host, (), |context| {
        context.draw_ui(|canvas| canvas.rect_rounded(x, y, w, h, color(tint), corner_radius))
    });
}
extern "C" fn draw_progress_bar(
    host: *mut c_void,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    value: f32,
    max_value: f32,
    corner_radius: f32,
    fill_color: Color4,
    bg_color: Color4,
) {
    with_current_context(host, (), |context| {
        context.draw_ui(|canvas| {
            canvas.progress_bar_styled(
                x,
                y,
                w,
                h,
                value,
                max_value,
                color(fill_color),
                color(bg_color),
                corner_radius,
            )
        })
    });
}
extern "C" fn report_state(host: *mut c_void, json: Slice) {
    with_current_context(host, (), |context| {
        let Some(json) = string_from(json) else {
            return;
        };
        match serde_json::from_str::<BTreeMap<String, String>>(&json) {
            Ok(values) => context.report_state(&values),
            Err(error) => report_error(host, slice_of(&error.to_string())),
        }
    });
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptBridgeError {
    #[error("Invalid UTF-8 in script bridge input.")]
    InvalidUtf8,
    #[error("Invalid script JSON: {0}")]
    Json(String),
    #[error("Unknown or ambiguous component type: {0}")]
    UnknownComponent(String),
    #[error("Component edit failed: {0}")]
    Component(String),
    #[error("Resource codec failed: {0}")]
    Resource(String),
}

fn decode_json<T: serde::de::DeserializeOwned>(text: &str) -> Result<T, ScriptBridgeError> {
    serde_json::from_str(text).map_err(|error| ScriptBridgeError::Json(error.to_string()))
}
fn encode_json<T: Serialize + ?Sized>(value: &T) -> Result<String, ScriptBridgeError> {
    diffuse_assets::swift_json::to_compact(value)
        .map_err(|error| ScriptBridgeError::Json(error.to_string()))
}
fn decode_slice<T: serde::de::DeserializeOwned>(value: Slice) -> Result<T, ScriptBridgeError> {
    decode_json(&string_from(value).ok_or(ScriptBridgeError::InvalidUtf8)?)
}
fn bridge_bytes(
    host: *mut c_void,
    body: impl FnOnce(&mut ScriptContext<'_, '_>) -> Result<Option<String>, ScriptBridgeError>,
) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| match body(context) {
        Ok(Some(text)) => owned_bytes(text.as_bytes()),
        Ok(None) => Bytes::EMPTY,
        Err(error) => {
            report_error(host, slice_of(&error.to_string()));
            Bytes::EMPTY
        }
    })
}
fn bridge_bool(
    host: *mut c_void,
    body: impl FnOnce(&mut ScriptContext<'_, '_>) -> Result<bool, ScriptBridgeError>,
) -> bool {
    with_current_context(host, false, |context| match body(context) {
        Ok(value) => value,
        Err(error) => {
            report_error(host, slice_of(&error.to_string()));
            false
        }
    })
}
fn component_schema(
    world: &RuntimeWorld,
    name: Slice,
) -> Result<ComponentSchema, ScriptBridgeError> {
    let name = string_from(name).ok_or(ScriptBridgeError::InvalidUtf8)?;
    world
        .component_registry
        .schema_named(&name)
        .cloned()
        .ok_or(ScriptBridgeError::UnknownComponent(name))
}

extern "C" fn get_component(host: *mut c_void, entity: u64, name: Slice) -> Bytes {
    bridge_bytes(host, |context| {
        context.phase_context.with_world(|world| {
            let schema = component_schema(world, name)?;
            world
                .component_data(&schema.type_id, entity_id(entity))
                .as_ref()
                .map(encode_json)
                .transpose()
        })
    })
}
extern "C" fn has_component(host: *mut c_void, entity: u64, name: Slice) -> bool {
    bridge_bool(host, |context| {
        context.phase_context.with_world(|world| {
            let schema = component_schema(world, name)?;
            Ok((schema.has)(world, entity_id(entity)))
        })
    })
}
extern "C" fn set_component(host: *mut c_void, entity: u64, name: Slice, json: Slice) -> bool {
    bridge_bool(host, |context| {
        let value: ComponentValue = decode_slice(json)?;
        context.phase_context.with_world(|world| {
            let schema = component_schema(world, name)?;
            world
                .set_component_data(
                    &value,
                    &schema.type_id,
                    entity_id(entity),
                    ComponentWriteMode::Replace,
                )
                .map_err(|error| ScriptBridgeError::Component(error.to_string()))?;
            Ok(true)
        })
    })
}
extern "C" fn remove_component(host: *mut c_void, entity: u64, name: Slice) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| {
        let result = context.phase_context.with_world(|world| {
            let schema = component_schema(world, name)?;
            let entity = entity_id(entity);
            let Some(previous) = world.component_data(&schema.type_id, entity) else {
                return Ok(Bytes::EMPTY);
            };
            // Encode and allocate before removal so a failure preserves the component.
            let text = encode_json(&previous)?;
            let bytes = PendingHostBytes(owned_bytes(text.as_bytes()));
            if !bytes.0.ptr.is_null() {
                (schema.remove)(entity, world);
            }
            Ok::<_, ScriptBridgeError>(bytes.release())
        });
        match result {
            Ok(bytes) => bytes,
            Err(error) => {
                report_error(host, slice_of(&error.to_string()));
                Bytes::EMPTY
            }
        }
    })
}

fn lanes3(value: Float3) -> [f32; 3] {
    [value.x, value.y, value.z]
}
fn lanes4(value: Float4) -> [f32; 4] {
    [value.x, value.y, value.z, value.w]
}
fn vector3(value: [f32; 3]) -> Float3 {
    Float3::new(value[0], value[1], value[2])
}
fn vector4(value: [f32; 4]) -> Float4 {
    Float4::new(value[0], value[1], value[2], value[3])
}
fn identity_rotation() -> [f32; 4] {
    [0.0, 0.0, 0.0, 1.0]
}
fn maximum_distance() -> f32 {
    f32::MAX
}

#[derive(Clone, Serialize, Deserialize)]
struct BoundsDocument {
    min: [f32; 3],
    max: [f32; 3],
}
impl From<SpatialAABB> for BoundsDocument {
    fn from(value: SpatialAABB) -> Self {
        Self {
            min: lanes3(value.min),
            max: lanes3(value.max),
        }
    }
}
impl BoundsDocument {
    fn native(self) -> SpatialAABB {
        SpatialAABB::new(vector3(self.min), vector3(self.max))
    }
}

#[derive(Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct QueryFilterDocument {
    exclude_entity: Option<u64>,
    ignored_entities: BTreeSet<u64>,
    include_triggers: bool,
    layer_id: Option<u16>,
    layer_mask: Option<u16>,
}
impl QueryFilterDocument {
    fn native(self) -> PhysicsQueryFilter {
        PhysicsQueryFilter::with_options(
            self.exclude_entity.map(entity_id),
            self.ignored_entities.into_iter().map(entity_id).collect(),
            self.include_triggers,
            self.layer_id,
            self.layer_mask.unwrap_or(u16::MAX),
        )
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RaycastDocument {
    origin: [f32; 3],
    direction: [f32; 3],
    #[serde(default = "maximum_distance")]
    max_distance: f32,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OverlapBoundsDocument {
    bounds: BoundsDocument,
    #[serde(default)]
    max_results: Option<i64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
enum ShapeDocument {
    Box { half_extents: [f32; 3] },
    Sphere { radius: f32 },
    Capsule { radius: f32, half_height: f32 },
}
impl ShapeDocument {
    fn native(self) -> PhysicsQueryShape {
        match self {
            Self::Box { half_extents } => PhysicsQueryShape::Box {
                half_extents: vector3(half_extents),
            },
            Self::Sphere { radius } => PhysicsQueryShape::Sphere { radius },
            Self::Capsule {
                radius,
                half_height,
            } => PhysicsQueryShape::Capsule {
                radius,
                half_height,
            },
        }
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OverlapShapeDocument {
    shape: ShapeDocument,
    position: [f32; 3],
    #[serde(default = "identity_rotation")]
    rotation: [f32; 4],
    #[serde(default)]
    max_results: Option<i64>,
}
#[derive(Deserialize)]
struct SweepBoundsDocument {
    bounds: BoundsDocument,
    translation: [f32; 3],
}
#[derive(Deserialize)]
struct SweepShapeDocument {
    shape: ShapeDocument,
    position: [f32; 3],
    #[serde(default = "identity_rotation")]
    rotation: [f32; 4],
    translation: [f32; 3],
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RaycastHitDocument {
    entity: u64,
    sub_shape_id: u32,
    distance: f32,
    position: [f32; 3],
    normal: [f32; 3],
    bounds: BoundsDocument,
    is_trigger: bool,
}
impl From<PhysicsRaycastHit> for RaycastHitDocument {
    fn from(hit: PhysicsRaycastHit) -> Self {
        Self {
            entity: hit.entity.raw_value(),
            sub_shape_id: hit.sub_shape_id,
            distance: hit.distance,
            position: lanes3(hit.position),
            normal: lanes3(hit.normal),
            bounds: hit.bounds.into(),
            is_trigger: hit.is_trigger,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OverlapHitDocument {
    entity: u64,
    sub_shape_id: u32,
    bounds: BoundsDocument,
    is_trigger: bool,
}
impl From<PhysicsOverlapHit> for OverlapHitDocument {
    fn from(hit: PhysicsOverlapHit) -> Self {
        Self {
            entity: hit.entity.raw_value(),
            sub_shape_id: hit.sub_shape_id,
            bounds: hit.bounds.into(),
            is_trigger: hit.is_trigger,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SweepHitDocument {
    entity: u64,
    sub_shape_id: u32,
    fraction: f32,
    distance: f32,
    position: [f32; 3],
    normal: [f32; 3],
    bounds: BoundsDocument,
    is_trigger: bool,
}
impl From<PhysicsSweepHit> for SweepHitDocument {
    fn from(hit: PhysicsSweepHit) -> Self {
        Self {
            entity: hit.entity.raw_value(),
            sub_shape_id: hit.sub_shape_id,
            fraction: hit.fraction,
            distance: hit.distance,
            position: lanes3(hit.position),
            normal: lanes3(hit.normal),
            bounds: hit.bounds.into(),
            is_trigger: hit.is_trigger,
        }
    }
}
extern "C" fn physics_raycast(host: *mut c_void, query: Slice, filter: Slice) -> Bytes {
    bridge_bytes(host, |context| {
        let query: RaycastDocument = decode_slice(query)?;
        let filter: QueryFilterDocument = decode_slice(filter)?;
        context
            .physics_raycast(
                PhysicsRaycastQuery::with_distance(
                    vector3(query.origin),
                    vector3(query.direction),
                    query.max_distance,
                ),
                filter.native(),
            )
            .map(RaycastHitDocument::from)
            .as_ref()
            .map(encode_json)
            .transpose()
    })
}
extern "C" fn physics_overlap_aabb(host: *mut c_void, query: Slice, filter: Slice) -> Bytes {
    bridge_bytes(host, |context| {
        let query: OverlapBoundsDocument = decode_slice(query)?;
        let filter: QueryFilterDocument = decode_slice(filter)?;
        let bounds = query.bounds.native();
        let query = query
            .max_results
            .map(|limit| PhysicsOverlapAABBQuery::with_max_results(bounds, limit))
            .unwrap_or_else(|| PhysicsOverlapAABBQuery::new(bounds));
        let hits: Vec<_> = context
            .physics_overlap_aabb(query, filter.native())
            .into_iter()
            .map(OverlapHitDocument::from)
            .collect();
        encode_json(&hits).map(Some)
    })
}
extern "C" fn physics_overlap_shape(host: *mut c_void, query: Slice, filter: Slice) -> Bytes {
    bridge_bytes(host, |context| {
        let document: OverlapShapeDocument = decode_slice(query)?;
        let filter: QueryFilterDocument = decode_slice(filter)?;
        let mut query = PhysicsOverlapShapeQuery::with_rotation(
            document.shape.native(),
            vector3(document.position),
            vector4(document.rotation),
        );
        if let Some(limit) = document.max_results {
            query.max_results = limit.max(0) as usize;
        }
        let hits: Vec<_> = context
            .physics_overlap_shape(query, filter.native())
            .into_iter()
            .map(OverlapHitDocument::from)
            .collect();
        encode_json(&hits).map(Some)
    })
}
extern "C" fn physics_sweep_aabb(host: *mut c_void, query: Slice, filter: Slice) -> Bytes {
    bridge_bytes(host, |context| {
        let query: SweepBoundsDocument = decode_slice(query)?;
        let filter: QueryFilterDocument = decode_slice(filter)?;
        context
            .physics_sweep_aabb(
                PhysicsSweepAABBQuery::new(query.bounds.native(), vector3(query.translation)),
                filter.native(),
            )
            .map(SweepHitDocument::from)
            .as_ref()
            .map(encode_json)
            .transpose()
    })
}
extern "C" fn physics_sweep_shape(host: *mut c_void, query: Slice, filter: Slice) -> Bytes {
    bridge_bytes(host, |context| {
        let query: SweepShapeDocument = decode_slice(query)?;
        let filter: QueryFilterDocument = decode_slice(filter)?;
        context
            .physics_sweep_shape(
                PhysicsSweepShapeQuery::with_rotation(
                    query.shape.native(),
                    vector3(query.position),
                    vector4(query.rotation),
                    vector3(query.translation),
                ),
                filter.native(),
            )
            .map(SweepHitDocument::from)
            .as_ref()
            .map(encode_json)
            .transpose()
    })
}

trait ResourceDocument: Serialize + serde::de::DeserializeOwned {
    type Native: Clone + Send + Sync + 'static;
    fn from_native(value: Self::Native) -> Self;
    fn native(self) -> Result<Self::Native, ScriptBridgeError>;
}

#[derive(Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct InputFrameDocument {
    held: BTreeSet<String>,
    just_pressed: BTreeSet<String>,
    just_released: BTreeSet<String>,
    axes: BTreeMap<String, f32>,
}
impl ResourceDocument for InputFrameDocument {
    type Native = InputFrameState;
    fn from_native(value: InputFrameState) -> Self {
        Self {
            held: value.held,
            just_pressed: value.just_pressed,
            just_released: value.just_released,
            axes: value.axes,
        }
    }
    fn native(self) -> Result<InputFrameState, ScriptBridgeError> {
        Ok(InputFrameState::new(
            self.held,
            self.just_pressed,
            self.just_released,
            self.axes,
        ))
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum TriggerKindDocument {
    Enter,
    Exit,
    Active,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TriggerEventDocument {
    trigger_entity: u64,
    other_entity: u64,
    kind: TriggerKindDocument,
}
impl From<TriggerEvent> for TriggerEventDocument {
    fn from(value: TriggerEvent) -> Self {
        Self {
            trigger_entity: value.trigger_entity.raw_value(),
            other_entity: value.other_entity.raw_value(),
            kind: match value.kind {
                TriggerEventKind::Enter => TriggerKindDocument::Enter,
                TriggerEventKind::Exit => TriggerKindDocument::Exit,
                TriggerEventKind::Active => TriggerKindDocument::Active,
            },
        }
    }
}
impl TriggerEventDocument {
    fn native(self) -> TriggerEvent {
        TriggerEvent::new(
            entity_id(self.trigger_entity),
            entity_id(self.other_entity),
            match self.kind {
                TriggerKindDocument::Enter => TriggerEventKind::Enter,
                TriggerKindDocument::Exit => TriggerEventKind::Exit,
                TriggerKindDocument::Active => TriggerEventKind::Active,
            },
        )
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct TriggerFrameDocument {
    enters: Vec<TriggerEventDocument>,
    exits: Vec<TriggerEventDocument>,
    active: Vec<TriggerEventDocument>,
}
impl ResourceDocument for TriggerFrameDocument {
    type Native = TriggerFrameResource;
    fn from_native(value: TriggerFrameResource) -> Self {
        Self {
            enters: value.enters.into_iter().map(Into::into).collect(),
            exits: value.exits.into_iter().map(Into::into).collect(),
            active: value.active.into_iter().map(Into::into).collect(),
        }
    }
    fn native(self) -> Result<TriggerFrameResource, ScriptBridgeError> {
        Ok(TriggerFrameResource::new(
            self.enters
                .into_iter()
                .map(TriggerEventDocument::native)
                .collect(),
            self.exits
                .into_iter()
                .map(TriggerEventDocument::native)
                .collect(),
            self.active
                .into_iter()
                .map(TriggerEventDocument::native)
                .collect(),
        ))
    }
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CharacterStateDocument {
    entity: u64,
    position: [f32; 3],
    rotation: [f32; 4],
    linear_velocity: [f32; 3],
    ground_state: u8,
    ground_normal: [f32; 3],
    ground_velocity: [f32; 3],
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ground_entity: Option<u64>,
    stance: CharacterStance,
}
impl CharacterStateDocument {
    fn from_native(value: CharacterState) -> Self {
        Self {
            entity: value.entity.raw_value(),
            position: lanes3(value.position),
            rotation: lanes4(value.rotation),
            linear_velocity: lanes3(value.linear_velocity),
            ground_state: value.ground_state.raw_value(),
            ground_normal: lanes3(value.ground_normal),
            ground_velocity: lanes3(value.ground_velocity),
            ground_entity: value.ground_entity.map(|entity| entity.raw_value()),
            stance: value.stance,
        }
    }
    fn native(self) -> Result<CharacterState, ScriptBridgeError> {
        let ground_state = CharacterGroundState::from_raw_value(self.ground_state)
            .ok_or_else(|| ScriptBridgeError::Json("Invalid character ground state.".into()))?;
        Ok(CharacterState::new(
            entity_id(self.entity),
            vector3(self.position),
            vector4(self.rotation),
            vector3(self.linear_velocity),
            ground_state,
            vector3(self.ground_normal),
            vector3(self.ground_velocity),
            self.ground_entity.map(entity_id),
            self.stance,
        ))
    }
}
fn entity_key(key: &str) -> Result<EntityID, ScriptBridgeError> {
    let raw: u64 = key
        .parse()
        .map_err(|_| ScriptBridgeError::Json(format!("Invalid entity key: {key}")))?;
    if raw.to_string() != key {
        return Err(ScriptBridgeError::Json(format!(
            "Noncanonical entity key: {key}"
        )));
    }
    Ok(entity_id(raw))
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct CharacterFrameDocument {
    states: BTreeMap<String, CharacterStateDocument>,
}
impl ResourceDocument for CharacterFrameDocument {
    type Native = CharacterStateFrameResource;
    fn from_native(value: CharacterStateFrameResource) -> Self {
        Self {
            states: value
                .states
                .into_iter()
                .map(|(key, value)| {
                    (
                        key.raw_value().to_string(),
                        CharacterStateDocument::from_native(value),
                    )
                })
                .collect(),
        }
    }
    fn native(self) -> Result<CharacterStateFrameResource, ScriptBridgeError> {
        let states = self
            .states
            .into_iter()
            .map(|(key, value)| Ok((entity_key(&key)?, value.native()?)))
            .collect::<Result<_, ScriptBridgeError>>()?;
        Ok(CharacterStateFrameResource { states })
    }
}
#[derive(Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct VehicleCommandDocument {
    throttle: f32,
    steering: f32,
    brake: f32,
    hand_brake: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    manual_gear: Option<i64>,
    clutch: f32,
}
impl Default for VehicleCommandDocument {
    fn default() -> Self {
        Self::from_native(VehicleCommand::default())
    }
}
impl VehicleCommandDocument {
    fn from_native(value: VehicleCommand) -> Self {
        Self {
            throttle: value.throttle,
            steering: value.steering,
            brake: value.brake,
            hand_brake: value.hand_brake,
            manual_gear: value.manual_gear,
            clutch: value.clutch,
        }
    }
    fn native(self) -> VehicleCommand {
        VehicleCommand::new(
            self.throttle,
            self.steering,
            self.brake,
            self.hand_brake,
            self.manual_gear,
            self.clutch,
        )
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct VehicleCommandFrameDocument {
    commands: BTreeMap<String, VehicleCommandDocument>,
}
impl ResourceDocument for VehicleCommandFrameDocument {
    type Native = VehicleCommandFrameResource;
    fn from_native(value: VehicleCommandFrameResource) -> Self {
        Self {
            commands: value
                .commands
                .into_iter()
                .map(|(key, value)| {
                    (
                        key.raw_value().to_string(),
                        VehicleCommandDocument::from_native(value),
                    )
                })
                .collect(),
        }
    }
    fn native(self) -> Result<VehicleCommandFrameResource, ScriptBridgeError> {
        Ok(VehicleCommandFrameResource::new(
            self.commands
                .into_iter()
                .map(|(key, value)| Ok((entity_key(&key)?, value.native())))
                .collect::<Result<_, ScriptBridgeError>>()?,
        ))
    }
}
extern "C" fn input_frame(host: *mut c_void) -> Bytes {
    bridge_bytes(host, |context| {
        encode_json(&InputFrameDocument::from_native(context.input())).map(Some)
    })
}
extern "C" fn trigger_events(host: *mut c_void) -> Bytes {
    bridge_bytes(host, |context| {
        encode_json(&TriggerFrameDocument::from_native(context.trigger_events())).map(Some)
    })
}
extern "C" fn character_state(host: *mut c_void) -> Bytes {
    bridge_bytes(host, |context| {
        context
            .character_state()
            .map(CharacterStateDocument::from_native)
            .as_ref()
            .map(encode_json)
            .transpose()
    })
}
extern "C" fn submit_vehicle_command(host: *mut c_void, json: Slice) -> bool {
    bridge_bool(host, |context| {
        let command: VehicleCommandDocument = decode_slice(json)?;
        context.submit_vehicle_command(command.native());
        Ok(true)
    })
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum AxisDocument {
    X,
    Y,
}
fn unit_scale() -> f32 {
    1.0
}
#[derive(Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum InputBindingDocument {
    Key {
        scancode: u32,
    },
    MouseButton {
        button: MouseButton,
    },
    KeyAxis {
        negative: u32,
        positive: u32,
    },
    MouseMotion {
        axis: AxisDocument,
        #[serde(default)]
        required_button: Option<MouseButton>,
        #[serde(default = "unit_scale")]
        scale: f32,
    },
    MouseWheel {
        axis: AxisDocument,
        #[serde(default = "unit_scale")]
        scale: f32,
    },
    GamepadButton {
        button: GamepadButton,
    },
    GamepadAxis {
        axis: GamepadAxis,
    },
}
impl From<InputBinding> for InputBindingDocument {
    fn from(value: InputBinding) -> Self {
        match value {
            InputBinding::Key(scancode) => Self::Key { scancode },
            InputBinding::MouseButton(button) => Self::MouseButton { button },
            InputBinding::KeyAxis { negative, positive } => Self::KeyAxis { negative, positive },
            InputBinding::MouseMotion {
                axis,
                required_button,
                scale,
            } => Self::MouseMotion {
                axis: match axis {
                    MouseMotionAxis::X => AxisDocument::X,
                    MouseMotionAxis::Y => AxisDocument::Y,
                },
                required_button,
                scale,
            },
            InputBinding::MouseWheel { axis, scale } => Self::MouseWheel {
                axis: match axis {
                    MouseWheelAxis::X => AxisDocument::X,
                    MouseWheelAxis::Y => AxisDocument::Y,
                },
                scale,
            },
            InputBinding::GamepadButton(button) => Self::GamepadButton { button },
            InputBinding::GamepadAxis(axis) => Self::GamepadAxis { axis },
        }
    }
}
impl InputBindingDocument {
    fn native(self) -> InputBinding {
        match self {
            Self::Key { scancode } => InputBinding::Key(scancode),
            Self::MouseButton { button } => InputBinding::MouseButton(button),
            Self::KeyAxis { negative, positive } => InputBinding::KeyAxis { negative, positive },
            Self::MouseMotion {
                axis,
                required_button,
                scale,
            } => InputBinding::MouseMotion {
                axis: match axis {
                    AxisDocument::X => MouseMotionAxis::X,
                    AxisDocument::Y => MouseMotionAxis::Y,
                },
                required_button,
                scale,
            },
            Self::MouseWheel { axis, scale } => InputBinding::MouseWheel {
                axis: match axis {
                    AxisDocument::X => MouseWheelAxis::X,
                    AxisDocument::Y => MouseWheelAxis::Y,
                },
                scale,
            },
            Self::GamepadButton { button } => InputBinding::GamepadButton(button),
            Self::GamepadAxis { axis } => InputBinding::GamepadAxis(axis),
        }
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct InputMapDocument {
    bindings: BTreeMap<String, Vec<InputBindingDocument>>,
}
impl ResourceDocument for InputMapDocument {
    type Native = InputActionMap;
    fn from_native(value: InputActionMap) -> Self {
        Self {
            bindings: value
                .bindings
                .into_iter()
                .map(|(key, values)| (key, values.into_iter().map(Into::into).collect()))
                .collect(),
        }
    }
    fn native(self) -> Result<InputActionMap, ScriptBridgeError> {
        Ok(InputActionMap::new(
            self.bindings
                .into_iter()
                .map(|(key, values)| {
                    (
                        key,
                        values
                            .into_iter()
                            .map(InputBindingDocument::native)
                            .collect(),
                    )
                })
                .collect(),
        ))
    }
}

fn color_lanes(value: InGameUIColor) -> [f32; 4] {
    [value.r, value.g, value.b, value.a]
}
#[derive(Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum CanvasCommandDocument {
    Label {
        text: String,
        x: f32,
        y: f32,
        font_size: f32,
        color: [f32; 4],
    },
    Rect {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        corner_radius: f32,
        color: [f32; 4],
    },
    ProgressBar {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        value: f32,
        max_value: f32,
        corner_radius: f32,
        fill_color: [f32; 4],
        bg_color: [f32; 4],
    },
}
impl From<InGameCanvasCommand> for CanvasCommandDocument {
    fn from(value: InGameCanvasCommand) -> Self {
        match value {
            InGameCanvasCommand::Label {
                text,
                x,
                y,
                font_size,
                color,
            } => Self::Label {
                text,
                x,
                y,
                font_size,
                color: color_lanes(color),
            },
            InGameCanvasCommand::Rect {
                x,
                y,
                w,
                h,
                color,
                corner_radius,
            } => Self::Rect {
                x,
                y,
                w,
                h,
                corner_radius,
                color: color_lanes(color),
            },
            InGameCanvasCommand::ProgressBar {
                x,
                y,
                w,
                h,
                value,
                max_value,
                fill_color,
                bg_color,
                corner_radius,
            } => Self::ProgressBar {
                x,
                y,
                w,
                h,
                value,
                max_value,
                corner_radius,
                fill_color: color_lanes(fill_color),
                bg_color: color_lanes(bg_color),
            },
        }
    }
}
impl CanvasCommandDocument {
    fn native(self) -> InGameCanvasCommand {
        match self {
            Self::Label {
                text,
                x,
                y,
                font_size,
                color: tint,
            } => InGameCanvasCommand::Label {
                text,
                x,
                y,
                font_size,
                color: color(Color4::new(tint)),
            },
            Self::Rect {
                x,
                y,
                w,
                h,
                corner_radius,
                color: tint,
            } => InGameCanvasCommand::Rect {
                x,
                y,
                w,
                h,
                corner_radius,
                color: color(Color4::new(tint)),
            },
            Self::ProgressBar {
                x,
                y,
                w,
                h,
                value,
                max_value,
                corner_radius,
                fill_color,
                bg_color,
            } => InGameCanvasCommand::ProgressBar {
                x,
                y,
                w,
                h,
                value,
                max_value,
                corner_radius,
                fill_color: color(Color4::new(fill_color)),
                bg_color: color(Color4::new(bg_color)),
            },
        }
    }
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct CanvasDocument {
    commands: Vec<CanvasCommandDocument>,
}
impl ResourceDocument for CanvasDocument {
    type Native = InGameCanvas;
    fn from_native(value: InGameCanvas) -> Self {
        Self {
            commands: value.commands.into_iter().map(Into::into).collect(),
        }
    }
    fn native(self) -> Result<InGameCanvas, ScriptBridgeError> {
        Ok(InGameCanvas {
            commands: self
                .commands
                .into_iter()
                .map(CanvasCommandDocument::native)
                .collect(),
        })
    }
}

type ResourceRead = dyn for<'phase, 'world> Fn(
        &ScriptContext<'phase, 'world>,
    ) -> Result<Option<String>, ScriptBridgeError>
    + Send
    + Sync;
type ResourceWrite = dyn for<'phase, 'world> Fn(
        &mut ScriptContext<'phase, 'world>,
        &str,
    ) -> Result<(), ScriptBridgeError>
    + Send
    + Sync;
type ResourceRemove = dyn for<'phase, 'world> Fn(&mut ScriptContext<'phase, 'world>) + Send + Sync;

// Cloned world registries share immutable codec functions, while resource values remain value-owned.
#[derive(Clone)]
struct ScriptResourceCodec {
    read: Arc<ResourceRead>,
    write: Arc<ResourceWrite>,
    remove: Arc<ResourceRemove>,
}

/// Native resource codecs are registered before script execution, under the
/// same names used by the SDK. Other names hold scene-owned JSON resources.
#[derive(Clone)]
pub struct ScriptResourceRegistry {
    codecs: BTreeMap<String, ScriptResourceCodec>,
}

impl Default for ScriptResourceRegistry {
    fn default() -> Self {
        let mut registry = Self {
            codecs: BTreeMap::new(),
        };
        registry.insert_document::<InputMapDocument>("InputActionMap");
        registry.insert_document::<InputFrameDocument>("InputFrameState");
        registry.insert_document::<CanvasDocument>("InGameCanvas");
        registry.insert_document::<TriggerFrameDocument>("TriggerFrameResource");
        registry.insert_document::<CharacterFrameDocument>("CharacterStateFrameResource");
        registry.insert_document::<VehicleCommandFrameDocument>("VehicleCommandFrameResource");
        registry.insert_document::<DebugStateDocument>("ScriptDebugState");
        registry
            .insert_codec::<crate::controllers::character_input_controller::CharacterLandEvent>(
                "CharacterLandEvent",
                |value| {
                    encode_json(&EntityEventDocument {
                        entity: value.entity.raw_value(),
                    })
                },
                |text| {
                    Ok(
                        crate::controllers::character_input_controller::CharacterLandEvent::new(
                            entity_id(decode_json::<EntityEventDocument>(text)?.entity),
                        ),
                    )
                },
            );
        registry.insert_codec::<crate::controllers::character_input_controller::CharacterLeaveGroundEvent>(
            "CharacterLeaveGroundEvent",
            |value| encode_json(&EntityEventDocument { entity: value.entity.raw_value() }),
            |text| Ok(crate::controllers::character_input_controller::CharacterLeaveGroundEvent::new(
                entity_id(decode_json::<EntityEventDocument>(text)?.entity))));
        registry.insert_codec::<crate::interop::component_registry_script_codec::ScriptAuthoringDefaults>(
            "ScriptAuthoringDefaults",
            |value| encode_json(&AuthoringDefaultsDocument { identifier: value.identifier.clone() }),
            |text| Ok(crate::interop::component_registry_script_codec::ScriptAuthoringDefaults::new(
                decode_json::<AuthoringDefaultsDocument>(text)?.identifier)));
        registry
    }
}

impl ScriptResourceRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a native resource with an existing Swift-compatible serde shape.
    pub fn register_json<R>(&mut self, name: &str) -> Result<(), ScriptBridgeError>
    where
        R: Clone + Send + Sync + Serialize + serde::de::DeserializeOwned + 'static,
    {
        self.register_codec::<R>(name, encode_json::<R>, decode_json::<R>)
    }

    /// Register custom conversion for a native resource which has no serde
    /// implementation. Decode failures leave the existing resource unchanged.
    pub fn register_codec<R: Clone + Send + Sync + 'static>(
        &mut self,
        name: &str,
        encode: fn(&R) -> Result<String, ScriptBridgeError>,
        decode: fn(&str) -> Result<R, ScriptBridgeError>,
    ) -> Result<(), ScriptBridgeError> {
        if name.is_empty() || self.codecs.contains_key(name) {
            return Err(ScriptBridgeError::Resource(format!(
                "Empty or duplicate resource name: {name}"
            )));
        }
        self.insert_codec::<R>(name, encode, decode);
        Ok(())
    }

    fn insert_codec<R: Clone + Send + Sync + 'static>(
        &mut self,
        name: &str,
        encode: fn(&R) -> Result<String, ScriptBridgeError>,
        decode: fn(&str) -> Result<R, ScriptBridgeError>,
    ) {
        self.codecs.insert(
            name.to_owned(),
            ScriptResourceCodec {
                read: Arc::new(move |context| {
                    context.resource::<R>().as_ref().map(encode).transpose()
                }),
                write: Arc::new(move |context, text| {
                    let value = decode(text)?;
                    context.set_resource(value);
                    Ok(())
                }),
                remove: Arc::new(|context| {
                    context.remove_resource::<R>();
                }),
            },
        );
    }

    fn insert_document<D: ResourceDocument>(&mut self, name: &str) {
        self.insert_codec::<D::Native>(name, encode_document::<D>, decode_document::<D>);
    }
}
fn encode_document<D: ResourceDocument>(value: &D::Native) -> Result<String, ScriptBridgeError> {
    encode_json(&D::from_native(value.clone()))
}
fn decode_document<D: ResourceDocument>(text: &str) -> Result<D::Native, ScriptBridgeError> {
    decode_json::<D>(text)?.native()
}
fn resource_codec(context: &ScriptContext<'_, '_>, name: &str) -> Option<ScriptResourceCodec> {
    static BUILT_INS: OnceLock<ScriptResourceRegistry> = OnceLock::new();
    context
        .resource::<ScriptResourceRegistry>()
        .and_then(|registry| registry.codecs.get(name).cloned())
        .or_else(|| {
            BUILT_INS
                .get_or_init(ScriptResourceRegistry::default)
                .codecs
                .get(name)
                .cloned()
        })
}

#[derive(Clone, Default)]
struct ScriptJsonResources(BTreeMap<String, ComponentValue>);

fn resource_name(value: Slice) -> Result<String, ScriptBridgeError> {
    let name = string_from(value).ok_or(ScriptBridgeError::InvalidUtf8)?;
    if name.is_empty() {
        return Err(ScriptBridgeError::Resource(
            "Resource name is empty.".into(),
        ));
    }
    Ok(name)
}
extern "C" fn get_resource(host: *mut c_void, name: Slice) -> Bytes {
    bridge_bytes(host, |context| {
        let name = resource_name(name)?;
        if let Some(codec) = resource_codec(context, &name) {
            return (codec.read)(context);
        }
        context
            .resource::<ScriptJsonResources>()
            .and_then(|values| values.0.get(&name).cloned())
            .as_ref()
            .map(encode_json)
            .transpose()
    })
}
extern "C" fn set_resource(host: *mut c_void, name: Slice, json: Slice) -> bool {
    bridge_bool(host, |context| {
        let name = resource_name(name)?;
        let text = string_from(json).ok_or(ScriptBridgeError::InvalidUtf8)?;
        // Validate even custom codecs' input as JSON before giving it to native code.
        let value: ComponentValue = decode_json(&text)?;
        if let Some(codec) = resource_codec(context, &name) {
            (codec.write)(context, &text)?;
        } else {
            let mut values = context
                .resource::<ScriptJsonResources>()
                .unwrap_or_default();
            values.0.insert(name, value);
            context.set_resource(values);
        }
        Ok(true)
    })
}
extern "C" fn remove_resource(host: *mut c_void, name: Slice) -> Bytes {
    with_current_context(host, Bytes::EMPTY, |context| {
        let result = (|| {
            let name = resource_name(name)?;
            let codec = resource_codec(context, &name);
            let text = if let Some(codec) = &codec {
                (codec.read)(context)?
            } else {
                context
                    .resource::<ScriptJsonResources>()
                    .and_then(|values| values.0.get(&name).cloned())
                    .as_ref()
                    .map(encode_json)
                    .transpose()?
            };
            let Some(text) = text else {
                return Ok(Bytes::EMPTY);
            };
            let bytes = PendingHostBytes(owned_bytes(text.as_bytes()));
            if !bytes.0.ptr.is_null() {
                if let Some(codec) = codec {
                    (codec.remove)(context);
                } else {
                    let mut values = context
                        .resource::<ScriptJsonResources>()
                        .unwrap_or_default();
                    values.0.remove(&name);
                    if values.0.is_empty() {
                        context.remove_resource::<ScriptJsonResources>();
                    } else {
                        context.set_resource(values);
                    }
                }
            }
            Ok::<_, ScriptBridgeError>(bytes.release())
        })();
        match result {
            Ok(bytes) => bytes,
            Err(error) => {
                report_error(host, slice_of(&error.to_string()));
                Bytes::EMPTY
            }
        }
    })
}

#[derive(Serialize, Deserialize)]
struct EntityEventDocument {
    entity: u64,
}
#[derive(Serialize, Deserialize)]
struct AuthoringDefaultsDocument {
    identifier: String,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(default)]
struct DebugStateDocument {
    entities: BTreeMap<String, BTreeMap<String, String>>,
}
impl ResourceDocument for DebugStateDocument {
    type Native = crate::interop::script_debug_state::ScriptDebugState;
    fn from_native(value: Self::Native) -> Self {
        Self {
            entities: value
                .entities
                .into_iter()
                .map(|(entity, values)| (entity.raw_value().to_string(), values))
                .collect(),
        }
    }
    fn native(self) -> Result<Self::Native, ScriptBridgeError> {
        Ok(crate::interop::script_debug_state::ScriptDebugState {
            entities: self
                .entities
                .into_iter()
                .map(|(key, values)| Ok((entity_key(&key)?, values)))
                .collect::<Result<_, ScriptBridgeError>>()?,
        })
    }
}
