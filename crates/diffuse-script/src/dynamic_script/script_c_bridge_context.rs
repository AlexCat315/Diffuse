//! Scoped context dispatch and stable per-instance HostApi state (D1).

use crate::core::script_context::ScriptContext;
use crate::core::script_definition::JsonValue;
use diffuse_kernel::in_game_canvas::{InGameCanvas, InGameUIColor};
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_graph::prefab::Prefab;
use diffuse_script_api::abi::{Bytes, Color4, HostApi, Slice, Transform3, slice_of};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    ffi::c_void,
    panic::AssertUnwindSafe,
    rc::Rc,
    sync::{Arc, Mutex},
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
