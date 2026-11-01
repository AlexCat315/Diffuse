//! Stable C exports generated in each script cdylib by `diffuse_scripts!`.

use crate::{
    abi::{ABI_VERSION, Bytes, HostApi, Slice, slice_of},
    authoring::{ScriptBehavior, ScriptDefinition, json},
    context::ScriptContext,
};
use core::{ffi::c_void, panic::AssertUnwindSafe};
use std::any::Any;

/// The host and its opaque instance outlive this object, including its destructor.
pub struct ScriptInstance {
    behavior: Box<dyn ScriptInstanceApi>,
    host: HostApi,
    disabled: bool,
}

pub trait ScriptInstanceApi: Send {
    fn on_start(&mut self, context: &ScriptContext);
    fn on_pre_physics(&mut self, context: &ScriptContext);
    fn on_update(&mut self, context: &ScriptContext);
    fn on_destroy(&mut self, context: &ScriptContext);
}
impl<B: ScriptBehavior> ScriptInstanceApi for B {
    fn on_start(&mut self, context: &ScriptContext) {
        ScriptBehavior::on_start(self, context);
    }
    fn on_pre_physics(&mut self, context: &ScriptContext) {
        ScriptBehavior::on_pre_physics(self, context);
    }
    fn on_update(&mut self, context: &ScriptContext) {
        ScriptBehavior::on_update(self, context);
    }
    fn on_destroy(&mut self, context: &ScriptContext) {
        ScriptBehavior::on_destroy(self, context);
    }
}

pub struct CatalogEntry {
    pub name: &'static str,
    pub definition: fn() -> &'static ScriptDefinition,
}
pub type Factory = fn(&str) -> Option<Box<dyn ScriptInstanceApi>>;

fn report(host: &HostApi, message: &str) {
    if let Some(report) = host.report_error {
        report(host.instance, slice_of(message));
    }
}
fn report_panic(host: Option<&HostApi>, operation: &str, payload: Box<dyn Any + Send>) {
    let detail = if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_owned()
    } else {
        "non-string panic payload".to_owned()
    };
    // An arbitrary panic_any payload may itself panic in Drop. It must not escape the FFI guard.
    std::mem::forget(payload);
    if let Some(host) = host {
        report(host, &format!("Rust script {operation} panicked: {detail}"));
    }
}

/// # Safety
/// A non-null host pointer must reference a readable table header and, after
/// version validation, a complete HostApi. Functions and instance remain live
/// until the resulting script instance has been destroyed.
unsafe fn host_from(host: *const HostApi) -> Option<HostApi> {
    if host.is_null() {
        return None;
    }
    // SAFETY: ABI version is always the first u32, including in older tables.
    if unsafe { host.cast::<u32>().read() } != ABI_VERSION {
        return None;
    }
    // SAFETY: matching versions have exactly this table layout.
    Some(unsafe { host.read() })
}

pub extern "C" fn diffuse_script_abi_version() -> u32 {
    match std::panic::catch_unwind(|| ABI_VERSION) {
        Ok(version) => version,
        Err(payload) => {
            report_panic(None, "ABI version", payload);
            0
        }
    }
}

/// # Safety
/// `name` is readable for this call; `host` satisfies host_from's contract.
pub unsafe fn diffuse_script_create(
    name: Slice,
    host: *const HostApi,
    factory: Factory,
) -> *mut c_void {
    // SAFETY: supplied by the exported wrapper's caller.
    let Some(host) = (unsafe { host_from(host) }) else {
        return core::ptr::null_mut();
    };
    match std::panic::catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller owns this UTF-8 range for the call's duration.
        let Some(name) = (unsafe { name.as_str() }) else {
            report(&host, "Invalid script name UTF-8.");
            return core::ptr::null_mut();
        };
        let Some(behavior) = factory(name) else {
            report(&host, &format!("Unknown script '{name}'."));
            return core::ptr::null_mut();
        };
        Box::into_raw(Box::new(ScriptInstance {
            behavior,
            host,
            disabled: false,
        }))
        .cast()
    })) {
        Ok(instance) => instance,
        Err(payload) => {
            report_panic(Some(&host), "creation", payload);
            core::ptr::null_mut()
        }
    }
}

/// # Safety
/// The instance is live, exclusively accessed, and created by this cdylib.
/// The supplied host belongs to it and satisfies host_from's contract.
unsafe fn run_lifecycle(
    instance: *mut c_void,
    host: *const HostApi,
    operation: &str,
    callback: impl FnOnce(&mut dyn ScriptInstanceApi, &ScriptContext),
) -> i32 {
    if instance.is_null() {
        return 1;
    }
    // SAFETY: the lifecycle wrapper guarantees exclusive access to this live allocation.
    let script = unsafe { &mut *instance.cast::<ScriptInstance>() };
    if script.disabled {
        return 1;
    }
    // SAFETY: the exported entry's caller guarantees a readable table.
    let Some(host) = (unsafe { host_from(host) }) else {
        script.disabled = true;
        report(&script.host, "Script HostApi version mismatch.");
        return 1;
    };
    if host.instance != script.host.instance {
        script.disabled = true;
        report(&script.host, "Script HostApi belongs to another instance.");
        return 1;
    }
    match std::panic::catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the host remains live for this callback; the context cannot be sent to another thread.
        let context = unsafe { ScriptContext::new(host) };
        callback(script.behavior.as_mut(), &context);
    })) {
        Ok(()) => 0,
        Err(payload) => {
            script.disabled = true;
            report_panic(Some(&host), operation, payload);
            1
        }
    }
}

/// # Safety
/// `instance` is live and exclusively accessed; `host` belongs to it.
pub unsafe extern "C" fn diffuse_script_on_start(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    // SAFETY: forwarded from the caller unchanged.
    unsafe {
        run_lifecycle(instance, host, "on_start", |script, context| {
            script.on_start(context)
        })
    }
}
/// # Safety
/// Same contract as diffuse_script_on_start.
pub unsafe extern "C" fn diffuse_script_on_pre_physics(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    // SAFETY: forwarded from the caller unchanged.
    unsafe {
        run_lifecycle(instance, host, "on_pre_physics", |script, context| {
            script.on_pre_physics(context)
        })
    }
}
/// # Safety
/// Same contract as diffuse_script_on_start.
pub unsafe extern "C" fn diffuse_script_on_update(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    // SAFETY: forwarded from the caller unchanged.
    unsafe {
        run_lifecycle(instance, host, "on_update", |script, context| {
            script.on_update(context)
        })
    }
}
/// # Safety
/// Same contract as diffuse_script_on_start.
pub unsafe extern "C" fn diffuse_script_on_destroy(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    // SAFETY: forwarded from the caller unchanged.
    unsafe {
        run_lifecycle(instance, host, "on_destroy", |script, context| {
            script.on_destroy(context)
        })
    }
}

/// # Safety
/// Destroy a live instance exactly once. Its host and opaque instance remain
/// valid until this function returns, including when a behavior destructor panics.
pub unsafe extern "C" fn diffuse_script_destroy(instance: *mut c_void) {
    if instance.is_null() {
        return;
    }
    // SAFETY: the caller transfers ownership of this SDK allocation exactly once.
    let script = unsafe { Box::from_raw(instance.cast::<ScriptInstance>()) };
    let host = script.host;
    if let Err(payload) = std::panic::catch_unwind(AssertUnwindSafe(|| drop(script))) {
        report_panic(Some(&host), "destruction", payload);
    }
}

/// Catalog returned from the host allocator, released with the same host's free.
///
/// # Safety
/// `host` satisfies host_from's contract. Its allocate entry returns writable,
/// initialized host-owned bytes of the requested length or Bytes::EMPTY on error.
pub unsafe fn catalog_bytes(entries: &[CatalogEntry], host: *const HostApi) -> Bytes {
    // SAFETY: supplied by the exported wrapper's caller.
    let Some(host) = (unsafe { host_from(host) }) else {
        return Bytes::EMPTY;
    };
    match std::panic::catch_unwind(AssertUnwindSafe(|| {
        let entries = entries
            .iter()
            .map(|entry| {
                json::JsonValue::Object(json::JsonObject::from([
                    ("name".into(), json::JsonValue::String(entry.name.into())),
                    ("definition".into(), (entry.definition)().codable_value()),
                ]))
            })
            .collect();
        let Some(text) = json::JsonValue::Array(entries).try_to_json() else {
            report(&host, "Script catalog contains non-finite property values.");
            return Bytes::EMPTY;
        };
        let Some(allocate) = host.allocate else {
            report(&host, "HostApi has no byte allocator.");
            return Bytes::EMPTY;
        };
        let bytes = allocate(text.len());
        if bytes.ptr.is_null() || bytes.len != text.len() || !bytes.owned {
            if bytes.owned
                && let Some(free) = host.free
            {
                free(bytes);
            }
            report(&host, "HostApi failed to allocate the script catalog.");
            return Bytes::EMPTY;
        }
        // SAFETY: host.allocate guarantees this writable range; it cannot overlap the script-owned String.
        unsafe {
            core::ptr::copy_nonoverlapping(text.as_ptr(), bytes.ptr, text.len());
        }
        bytes
    })) {
        Ok(bytes) => bytes,
        Err(payload) => {
            report_panic(Some(&host), "catalog", payload);
            Bytes::EMPTY
        }
    }
}

/// Emits every C entry in the final cdylib so dependency dead-stripping cannot remove them.
#[macro_export]
macro_rules! diffuse_scripts {
    ($($script:ty),+ $(,)?) => {
        #[cfg(panic = "abort")]
        compile_error!("Diffuse scripts require panic=unwind so lifecycle failures can be reported without terminating the host.");
        #[unsafe(no_mangle)]
        pub extern "C" fn diffuse_script_abi_version() -> u32 { $crate::export::diffuse_script_abi_version() }
        /// # Safety
        /// The host table and allocator satisfy the script ABI contract.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_catalog(host: *const $crate::abi::HostApi) -> $crate::abi::Bytes {
            // SAFETY: the loader supplies a live host table and allocator.
            unsafe { $crate::export::catalog_bytes(&[$($crate::export::CatalogEntry {
                name: stringify!($script),
                definition: || {
                    use $crate::authoring::ResolveScriptDefinition as _;
                    let probe = $crate::authoring::ScriptDefinitionProbe::<$script>::new();
                    (&&probe).resolve_script_definition()
                },
            },)+], host) }
        }
        pub fn diffuse_script_factory(name: &str) -> Option<Box<dyn $crate::export::ScriptInstanceApi>> {
            $(if name == stringify!($script) { return Some(Box::new(<$script as ::core::default::Default>::default())); })+
            None
        }
        /// # Safety
        /// The name and host remain live for this call; the host outlives the created instance.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_create(name: $crate::abi::Slice, host: *const $crate::abi::HostApi) -> *mut ::core::ffi::c_void {
            // SAFETY: the loader supplies a live host and name.
            unsafe { $crate::export::diffuse_script_create(name, host, diffuse_script_factory) }
        }
        /// # Safety
        /// The instance is live, exclusively accessed and belongs to this host.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_on_start(instance: *mut ::core::ffi::c_void, host: *const $crate::abi::HostApi) -> i32 {
            // SAFETY: forwarded unchanged from the loader.
            unsafe { $crate::export::diffuse_script_on_start(instance, host) }
        }
        /// # Safety
        /// The instance is live, exclusively accessed and belongs to this host.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_on_pre_physics(instance: *mut ::core::ffi::c_void, host: *const $crate::abi::HostApi) -> i32 {
            // SAFETY: forwarded unchanged from the loader.
            unsafe { $crate::export::diffuse_script_on_pre_physics(instance, host) }
        }
        /// # Safety
        /// The instance is live, exclusively accessed and belongs to this host.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_on_update(instance: *mut ::core::ffi::c_void, host: *const $crate::abi::HostApi) -> i32 {
            // SAFETY: forwarded unchanged from the loader.
            unsafe { $crate::export::diffuse_script_on_update(instance, host) }
        }
        /// # Safety
        /// The instance is live, exclusively accessed and belongs to this host.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_on_destroy(instance: *mut ::core::ffi::c_void, host: *const $crate::abi::HostApi) -> i32 {
            // SAFETY: forwarded unchanged from the loader.
            unsafe { $crate::export::diffuse_script_on_destroy(instance, host) }
        }
        /// # Safety
        /// The live instance is destroyed once; its host remains live through this call.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_destroy(instance: *mut ::core::ffi::c_void) {
            // SAFETY: the loader transfers ownership once.
            unsafe { $crate::export::diffuse_script_destroy(instance) }
        }
    };
}
