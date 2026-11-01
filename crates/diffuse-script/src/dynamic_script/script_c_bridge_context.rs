//! Scoped context dispatch and stable per-instance HostApi state (D1).

use crate::core::script_context::ScriptContext;
use diffuse_scene::entity_id::EntityID;
use diffuse_script_api::abi::{Bytes, HostApi, Slice};
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
