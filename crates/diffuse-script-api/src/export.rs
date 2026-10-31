//! The exported entry points a script cdylib provides.
//!
//! MIGRATION.md §4 D1 fixes the surface: `diffuse_script_abi_version`,
//! `diffuse_script_catalog`, `diffuse_script_create`, the four lifecycle entry
//! points and `diffuse_script_destroy`. [`diffuse_scripts!`] generates the
//! catalog-dependent ones. Every entry point wraps its body in `catch_unwind`, so
//! a panic is reported as a script error and never unwinds across the FFI
//! boundary.

use core::ffi::c_void;
use core::panic::AssertUnwindSafe;

use crate::abi::{ABI_VERSION, Bytes, HostApi, Slice};
use crate::authoring::{ScriptBehavior, ScriptDefinition, json};
use crate::context::ScriptContext;

/// One script instance as stored behind `diffuse_script_create`'s pointer.
pub struct ScriptInstance {
    behavior: Box<dyn ScriptInstanceApi>,
}

/// Object-safe view of [`ScriptBehavior`] used behind the FFI pointer.
pub trait ScriptInstanceApi {
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

/// A catalog entry: the script's name and its authoring definition.
pub struct CatalogEntry {
    pub name: &'static str,
    pub definition: fn() -> &'static ScriptDefinition,
}

/// Builds one instance for a catalog name; the generated macro supplies this.
pub type Factory = fn(&str) -> Option<Box<dyn ScriptInstanceApi>>;

/// Runs `body`, converting a panic into the supplied fallback.
fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(_) => fallback,
    }
}

/// Wraps a raw host table pointer into a [`ScriptContext`].
///
/// # Safety
///
/// `host` must point at a live `HostApi` for the duration of the callback.
unsafe fn context_from(host: *const HostApi) -> Option<ScriptContext> {
    if host.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees a valid, live table.
    let table = unsafe { *host };
    if table.abi_version != ABI_VERSION {
        return None;
    }
    Some(ScriptContext::new(table))
}

/// Reads a string slice argument defensively.
fn string_from(slice: Slice) -> Option<String> {
    slice.as_str().map(str::to_string)
}

/// Erases an instance pointer back to the concrete box.
///
/// # Safety
///
/// `ptr` must come from `diffuse_script_create` and not be destroyed yet.
unsafe fn instance_from<'a>(ptr: *mut c_void) -> Option<&'a mut ScriptInstance> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees the pointer came from `create`.
    Some(unsafe { &mut *(ptr as *mut ScriptInstance) })
}

/// The engine's ABI version. The host refuses to load a mismatched library.
#[unsafe(no_mangle)]
pub extern "C" fn diffuse_script_abi_version() -> u32 {
    ABI_VERSION
}

/// Creates one script instance; null means "unknown name or host mismatch".
///
/// `factory` is a Rust function pointer, so this entry point is `extern "Rust"`
/// rather than `extern "C"`; only the generated `diffuse_script_create_default`
/// is the C-visible wrapper.
///
/// # Safety
///
/// `host` must be a live table when non-null.
pub unsafe fn diffuse_script_create(
    name: Slice,
    host: *const HostApi,
    factory: Factory,
) -> *mut c_void {
    guard(core::ptr::null_mut(), || {
        let Some(name) = string_from(name) else {
            return core::ptr::null_mut();
        };
        // SAFETY: `diffuse_script_create`'s caller guarantees a live table.
        if unsafe { context_from(host) }.is_none() {
            return core::ptr::null_mut();
        }
        match factory(&name) {
            Some(behavior) => Box::into_raw(Box::new(ScriptInstance { behavior })) as *mut c_void,
            None => core::ptr::null_mut(),
        }
    })
}

/// Runs one lifecycle callback, returning 0 on success and 1 on failure.
fn run_lifecycle(
    instance: *mut c_void,
    host: *const HostApi,
    callback: impl FnOnce(&mut ScriptInstance, &ScriptContext),
) -> i32 {
    guard(1, || {
        // SAFETY: the caller of the exported wrapper guarantees these pointers.
        // SAFETY: the exported wrapper's caller guarantees both pointers.
        let Some(script) = (unsafe { instance_from(instance) }) else {
            return 1;
        };
        // SAFETY: `host` points at a live table.
        let Some(context) = (unsafe { context_from(host) }) else {
            return 1;
        };
        callback(script, &context);
        0
    })
}

/// Runs `on_start`.
///
/// # Safety
///
/// `instance` must come from [`diffuse_script_create`]; `host` must be live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn diffuse_script_on_start(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    run_lifecycle(instance, host, |script, context| {
        script.behavior.on_start(context)
    })
}

/// Runs `on_pre_physics`.
///
/// # Safety
///
/// See [`diffuse_script_on_start`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn diffuse_script_on_pre_physics(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    run_lifecycle(instance, host, |script, context| {
        script.behavior.on_pre_physics(context)
    })
}

/// Runs `on_update` (Swift's `onTick`).
///
/// # Safety
///
/// See [`diffuse_script_on_start`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn diffuse_script_on_update(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    run_lifecycle(instance, host, |script, context| {
        script.behavior.on_update(context)
    })
}

/// Runs `on_destroy`.
///
/// # Safety
///
/// See [`diffuse_script_on_start`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn diffuse_script_on_destroy(
    instance: *mut c_void,
    host: *const HostApi,
) -> i32 {
    run_lifecycle(instance, host, |script, context| {
        script.behavior.on_destroy(context)
    })
}

/// Releases an instance created by [`diffuse_script_create`].
///
/// # Safety
///
/// `instance` must come from [`diffuse_script_create`] and be destroyed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn diffuse_script_destroy(instance: *mut c_void) {
    guard((), || {
        if instance.is_null() {
            return;
        }
        // SAFETY: the caller guarantees the pointer came from `create`.
        drop(unsafe { Box::from_raw(instance as *mut ScriptInstance) });
    })
}

/// Serializes the catalog to host-owned JSON bytes.
pub fn catalog_bytes(entries: &[CatalogEntry]) -> Bytes {
    let mut array = Vec::with_capacity(entries.len());
    for entry in entries {
        let definition = (entry.definition)();
        let mut properties = Vec::with_capacity(definition.properties.len());
        for property in &definition.properties {
            let mut object = json::JsonObject::new();
            object.insert(
                "key".to_string(),
                json::JsonValue::String(property.key.clone()),
            );
            object.insert(
                "label".to_string(),
                json::JsonValue::String(property.label.clone()),
            );
            object.insert(
                "defaultValue".to_string(),
                property.default_value.json_value(),
            );
            let mut option_values = Vec::with_capacity(property.options.len());
            for option in &property.options {
                let mut option_object = json::JsonObject::new();
                option_object.insert(
                    "label".to_string(),
                    json::JsonValue::String(option.label.clone()),
                );
                option_object.insert("value".to_string(), option.value.json_value());
                option_values.push(json::JsonValue::Object(option_object));
            }
            object.insert("options".to_string(), json::JsonValue::Array(option_values));
            properties.push(json::JsonValue::Object(object));
        }
        let mut object = json::JsonObject::new();
        object.insert(
            "name".to_string(),
            json::JsonValue::String(entry.name.to_string()),
        );
        object.insert("properties".to_string(), json::JsonValue::Array(properties));
        array.push(json::JsonValue::Object(object));
    }

    let text = json::JsonValue::Array(array).to_json();
    let mut bytes = text.into_bytes();
    let slice = Bytes {
        ptr: bytes.as_mut_ptr(),
        len: bytes.len(),
        owned: true,
    };
    core::mem::forget(bytes);
    slice
}

/// Generates `diffuse_script_catalog` and the factory used by
/// [`diffuse_script_create`]'s callers.
///
/// ```ignore
/// diffuse_scripts!(CrystalRush);
/// ```
#[macro_export]
macro_rules! diffuse_scripts {
    ($($script:ty),+ $(,)?) => {
        /// The script catalog as JSON.
        #[unsafe(no_mangle)]
        pub extern "C" fn diffuse_script_catalog() -> $crate::abi::Bytes {
            $crate::export::catalog_bytes(&[
                $(
                    $crate::export::CatalogEntry {
                        name: stringify!($script),
                        definition: <$script as $crate::ScriptDefinitionSource>::definition,
                    },
                )+
            ])
        }

        /// The catalog factory, ready to pass to `diffuse_script_create`.
        pub fn diffuse_script_factory(
            name: &str,
        ) -> Option<Box<dyn $crate::export::ScriptInstanceApi>> {
            $(
                if name == stringify!($script) {
                    return Some(Box::new(<$script as ::core::default::Default>::default()));
                }
            )+
            None
        }

        /// Creates one instance through the generated factory.
        ///
        /// # Safety
        ///
        /// `host` must be a live table when non-null.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn diffuse_script_create_default(
            name: $crate::abi::Slice,
            host: *const $crate::abi::HostApi,
        ) -> *mut ::core::ffi::c_void {
            unsafe { $crate::export::diffuse_script_create(name, host, diffuse_script_factory) }
        }
    };
}
