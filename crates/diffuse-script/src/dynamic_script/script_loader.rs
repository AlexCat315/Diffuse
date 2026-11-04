//! D1: load a compiled script cdylib and expose its SDK exports as native
//! [`Script`] values.
//!
//! Swift loaded Swift-script dylibs through `coveCreateScript` and
//! `coveScriptDefinition`. Rust scripts are cdylibs built against
//! `diffuse-script-api`, whose stable C ABI is `diffuse_script_abi_version`,
//! `diffuse_script_catalog`, `diffuse_script_create`, the four lifecycle
//! entries and `diffuse_script_destroy` (MIGRATION.md §4 D1). The loader
//! validates the ABI version, reads the catalog into native
//! [`ScriptDefinition`]s and hands out factories whose [`Script`]s drive the
//! SDK instance through the engine-side [`HostApi`] table built by
//! `script_c_bridge_context`.

use crate::core::script_definition::ScriptDefinition;
use crate::core::script_lifecycle::{Script, ScriptCallback};
use crate::dynamic_script::script_c_bridge_context::{
    ScriptHostInstance, free, host_api, with_host_context,
};
#[cfg(unix)]
use core::ffi::{CStr, c_char};
use diffuse_script_api::abi::{ABI_VERSION, HostApi, slice_of};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    ffi::CString,
    sync::{Arc, Mutex, MutexGuard},
};

/// The loaded cdylib's SDK entry points, resolved once at load time.
#[derive(Clone, Copy)]
struct ScriptSymbols {
    catalog: unsafe extern "C" fn(*const HostApi) -> diffuse_script_api::abi::Bytes,
    create: unsafe extern "C" fn(
        name: diffuse_script_api::abi::Slice,
        host: *const HostApi,
    ) -> *mut core::ffi::c_void,
    on_start: unsafe extern "C" fn(*mut core::ffi::c_void, *const HostApi) -> i32,
    on_pre_physics: unsafe extern "C" fn(*mut core::ffi::c_void, *const HostApi) -> i32,
    on_update: unsafe extern "C" fn(*mut core::ffi::c_void, *const HostApi) -> i32,
    on_destroy: unsafe extern "C" fn(*mut core::ffi::c_void, *const HostApi) -> i32,
    destroy: unsafe extern "C" fn(*mut core::ffi::c_void),
}

const ABI_VERSION_SYMBOL: &str = "diffuse_script_abi_version";
const CATALOG_SYMBOL: &str = "diffuse_script_catalog";
const CREATE_SYMBOL: &str = "diffuse_script_create";
const ON_START_SYMBOL: &str = "diffuse_script_on_start";
const ON_PRE_PHYSICS_SYMBOL: &str = "diffuse_script_on_pre_physics";
const ON_UPDATE_SYMBOL: &str = "diffuse_script_on_update";
const ON_DESTROY_SYMBOL: &str = "diffuse_script_on_destroy";
const DESTROY_SYMBOL: &str = "diffuse_script_destroy";

#[cfg(unix)]
type LibraryHandle = *mut core::ffi::c_void;
#[cfg(windows)]
type LibraryHandle = win32::HMODULE;
#[cfg(not(any(unix, windows)))]
type LibraryHandle = *mut core::ffi::c_void;

/// One mapped script image and its resolved exports.
///
/// Rust cdylibs register panic hooks, thread-locals and static state
/// process-wide when their first instance is created. Unmapping an image
/// leaves those records pointing into freed memory, even after every
/// [`Script`] has been released. The OS loader's reference is therefore kept
/// for the lifetime of the process: `unload` drops the loader's map entries
/// and nothing ever calls `dlclose`/`FreeLibrary`.
struct LoadedLibrary {
    _handle: LibraryHandle,
    symbols: ScriptSymbols,
    definitions: BTreeMap<String, ScriptDefinition>,
}

// SAFETY: the handle is an opaque OS loader token and the symbols are function
// pointers into the mapped image; both stay valid for the process lifetime and
// the loader never mutates them after construction.
unsafe impl Send for LoadedLibrary {}
unsafe impl Sync for LoadedLibrary {}

/// Owns one SDK script instance and keeps its HostApi world alive.
///
/// Every native [`ScriptCallback`] holds a clone of the guard's `Arc`, so the
/// guard drops exactly when the last [`Script`] clone is released — the point
/// where `diffuse_script_destroy` must run.
struct InstanceGuard {
    instance: *mut core::ffi::c_void,
    /// SDK lifecycle functions require exclusive access to the script instance.
    invocation: Mutex<()>,
    /// The HostApi instance allocation the SDK instance was created against.
    /// It must outlive the SDK destructor, including a panicking behavior
    /// `Drop`, which the SDK catches and reports (MIGRATION.md §10).
    host: Arc<ScriptHostInstance>,
    /// The image the instance was created from. Factories and instances retain
    /// it like Swift's `Script.retaining(library)`.
    _image: Arc<LoadedLibrary>,
    destroy: unsafe extern "C" fn(*mut core::ffi::c_void),
}

// SAFETY: the SDK behavior is Send and `invocation` serializes every access to
// its opaque instance. The last Arc destroys it only after all callbacks end;
// `host` remains alive through destruction.
unsafe impl Send for InstanceGuard {}
unsafe impl Sync for InstanceGuard {}

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        // SAFETY: the guard is the last owner of an instance created by this
        // library's create entry; the SDK destroys it exactly once. Fields drop
        // after this body, so `host` still holds its strong reference — the
        // HostApi instance allocation outlives the destructor, which can still
        // report errors through it (MIGRATION.md §10).
        unsafe { (self.destroy)(self.instance) };
    }
}

type ScriptLifecycleEntry = unsafe extern "C" fn(*mut core::ffi::c_void, *const HostApi) -> i32;

/// Builds a native [`Script`] around one fresh SDK instance from `image`.
fn build_script(image: &Arc<LoadedLibrary>, name: &str) -> Result<Script, ScriptLoadError> {
    let host = Arc::new(ScriptHostInstance::default());
    let table = host_api(&host);
    // SAFETY: the table stays alive for this call; the SDK copies it, and the
    // guard below keeps its instance allocation (`host`) alive through destroy.
    let instance = unsafe { (image.symbols.create)(slice_of(name), &table) };
    if instance.is_null() {
        let errors = host.take_errors();
        return Err(ScriptLoadError::CreationFailed {
            name: name.to_owned(),
            message: if errors.is_empty() {
                "Script factory returned a null instance.".to_owned()
            } else {
                errors.join("\n")
            },
        });
    }
    let guard = Arc::new(InstanceGuard {
        instance,
        invocation: Mutex::new(()),
        host,
        _image: image.clone(),
        destroy: image.symbols.destroy,
    });
    Ok(Script::new(
        Some(lifecycle_callback(guard.clone(), image.symbols.on_start)),
        Some(lifecycle_callback(
            guard.clone(),
            image.symbols.on_pre_physics,
        )),
        Some(lifecycle_callback(guard.clone(), image.symbols.on_update)),
        Some(lifecycle_callback(guard, image.symbols.on_destroy)),
    ))
}

/// Wraps one SDK lifecycle entry in the engine-side HostApi invocation scope.
///
/// `with_host_context` installs the native [`ScriptContext`] for the table's
/// time/input/character/allocation entries and drains reported errors into the
/// context's `ScriptErrorState` resource. Panics inside the behavior are caught
/// by the SDK entry itself — reported, instance deactivated, never unwound.
fn lifecycle_callback(guard: Arc<InstanceGuard>, entry: ScriptLifecycleEntry) -> ScriptCallback {
    Arc::new(move |context| {
        let _invocation = guard
            .invocation
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let _ = with_host_context(&guard.host, context, |table: &HostApi| {
            // SAFETY: the instance is live for this call (the guard releases it
            // only through destroy) and `table`'s instance pointer is the one
            // the instance was created with, as the SDK requires.
            unsafe { entry(guard.instance, table) }
        });
    })
}

#[derive(Deserialize)]
struct ScriptCatalogEntry {
    name: String,
    definition: ScriptDefinition,
}

/// Host-allocated catalog bytes must be released on every decoding path.
struct CatalogBytes(diffuse_script_api::abi::Bytes);
impl Drop for CatalogBytes {
    fn drop(&mut self) {
        free(self.0);
    }
}

fn read_catalog(
    catalog: unsafe extern "C" fn(*const HostApi) -> diffuse_script_api::abi::Bytes,
) -> Result<BTreeMap<String, ScriptDefinition>, ScriptLoadError> {
    let host = Arc::new(ScriptHostInstance::default());
    let table = host_api(&host);
    // SAFETY: the SDK receives a live table and returns a host-allocated buffer.
    let bytes = CatalogBytes(unsafe { catalog(&table) });
    let errors = host.take_errors();
    if !errors.is_empty() {
        return Err(ScriptLoadError::InvalidCatalog(errors.join("\n")));
    }
    if bytes.0.ptr.is_null() || bytes.0.len == 0 || !bytes.0.owned {
        return Err(ScriptLoadError::InvalidCatalog(
            "Script catalog did not return host-owned JSON bytes.".to_owned(),
        ));
    }
    // SAFETY: the matching SDK ABI guarantees this initialized host-owned range.
    let text = unsafe { core::slice::from_raw_parts(bytes.0.ptr, bytes.0.len) };
    let entries: Vec<ScriptCatalogEntry> = serde_json::from_slice(text)
        .map_err(|error| ScriptLoadError::InvalidCatalog(error.to_string()))?;
    let mut definitions = BTreeMap::new();
    for entry in entries {
        if entry.name.is_empty() || definitions.contains_key(&entry.name) {
            return Err(ScriptLoadError::InvalidCatalog(format!(
                "Empty or duplicate script name: {:?}",
                entry.name,
            )));
        }
        definitions.insert(entry.name, entry.definition);
    }
    if definitions.is_empty() {
        return Err(ScriptLoadError::InvalidCatalog(
            "Script catalog is empty.".to_owned(),
        ));
    }
    Ok(definitions)
}

/// Each call creates an isolated instance or returns its SDK creation error.
pub type ScriptFactory = Arc<dyn Fn() -> Result<Script, ScriptLoadError> + Send + Sync>;

struct LoadedRegistration {
    image: Arc<LoadedLibrary>,
    script_name: String,
}

/// Shared loader state publishes the selected script and its metadata atomically.
#[derive(Default)]
pub struct ScriptLoader {
    loaded_libraries: Mutex<BTreeMap<String, LoadedRegistration>>,
}

impl ScriptLoader {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock_libraries(&self) -> MutexGuard<'_, BTreeMap<String, LoadedRegistration>> {
        self.loaded_libraries
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    /// Load the only script in a library. Multiple scripts require an explicit
    /// selection through `load_named_factory`; no alphabetical fallback is used.
    pub fn load_factory(
        &self,
        script_id: &str,
        library_path: &str,
    ) -> Result<ScriptFactory, ScriptLoadError> {
        self.load_selected_factory(script_id, library_path, None)
    }

    /// Select one named script from a multi-script cdylib catalog.
    pub fn load_named_factory(
        &self,
        script_id: &str,
        library_path: &str,
        script_name: &str,
    ) -> Result<ScriptFactory, ScriptLoadError> {
        self.load_selected_factory(script_id, library_path, Some(script_name))
    }

    fn load_selected_factory(
        &self,
        script_id: &str,
        library_path: &str,
        selected_name: Option<&str>,
    ) -> Result<ScriptFactory, ScriptLoadError> {
        let handle = open_library(library_path)?;
        let abi_version = required_symbol(handle, ABI_VERSION_SYMBOL)?;
        validate_abi_version(abi_version)?;
        let symbols = resolve_symbols(handle)?;
        let definitions = read_catalog(symbols.catalog)?;
        let script_name = match selected_name {
            Some(name) if definitions.contains_key(name) => name.to_owned(),
            Some(name) => return Err(ScriptLoadError::ScriptNotFound(name.to_owned())),
            None if definitions.len() == 1 => {
                definitions.keys().next().cloned().ok_or_else(|| {
                    ScriptLoadError::InvalidCatalog("Script catalog is empty.".to_owned())
                })?
            }
            None => {
                return Err(ScriptLoadError::ScriptSelectionRequired(
                    definitions.keys().cloned().collect(),
                ));
            }
        };
        let image = Arc::new(LoadedLibrary {
            _handle: handle,
            symbols,
            definitions,
        });
        // All fallible loading and selection work completes before replacing a
        // generation; metadata and image are visible under the same lock.
        self.lock_libraries().insert(
            script_id.to_owned(),
            LoadedRegistration {
                image: image.clone(),
                script_name: script_name.clone(),
            },
        );
        Ok(Arc::new(move || build_script(&image, &script_name)))
    }

    pub fn definition(&self, script_id: &str) -> ScriptDefinition {
        self.lock_libraries()
            .get(script_id)
            .and_then(|registration| {
                registration
                    .image
                    .definitions
                    .get(&registration.script_name)
            })
            .cloned()
            .unwrap_or_default()
    }

    pub fn catalog_definitions(&self, script_id: &str) -> BTreeMap<String, ScriptDefinition> {
        self.lock_libraries()
            .get(script_id)
            .map(|registration| registration.image.definitions.clone())
            .unwrap_or_default()
    }

    /// Existing factories and instances retain their generation after unload.
    pub fn unload(&self, script_id: &str) {
        self.lock_libraries().remove(script_id);
    }

    pub fn unload_all(&self) {
        self.lock_libraries().clear();
    }
}

impl Drop for ScriptLoader {
    fn drop(&mut self) {
        self.unload_all();
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptLoadError {
    #[error("Loading the script dynamic library failed: {0}")]
    DlopenFailed(String),
    #[error("Symbol not found in script library: {0}")]
    SymbolNotFound(String),
    #[error("Invalid script catalog: {0}")]
    InvalidCatalog(String),
    #[error("Select a script from this library: {0:?}")]
    ScriptSelectionRequired(Vec<String>),
    #[error("Script not found in catalog: {0}")]
    ScriptNotFound(String),
    #[error("Creating script '{name}' failed: {message}")]
    CreationFailed { name: String, message: String },
    #[error("Dynamic script loading is not supported on this platform.")]
    UnsupportedPlatform,
    #[error(
        "Script library targets ABI version {found}, but this engine requires {expected}. Rebuild the script against diffuse-script-api {expected}."
    )]
    AbiVersionMismatch { found: u32, expected: u32 },
}

fn resolve_symbols(handle: LibraryHandle) -> Result<ScriptSymbols, ScriptLoadError> {
    Ok(ScriptSymbols {
        catalog: required_symbol(handle, CATALOG_SYMBOL)?,
        create: required_symbol(handle, CREATE_SYMBOL)?,
        on_start: required_symbol(handle, ON_START_SYMBOL)?,
        on_pre_physics: required_symbol(handle, ON_PRE_PHYSICS_SYMBOL)?,
        on_update: required_symbol(handle, ON_UPDATE_SYMBOL)?,
        on_destroy: required_symbol(handle, ON_DESTROY_SYMBOL)?,
        destroy: required_symbol(handle, DESTROY_SYMBOL)?,
    })
}

fn required_symbol<T: Copy>(handle: LibraryHandle, name: &str) -> Result<T, ScriptLoadError> {
    symbol(handle, name).ok_or_else(|| ScriptLoadError::SymbolNotFound(name.to_string()))
}

/// The D1 ABI gate: refuse a library whose SDK disagrees with this engine
/// before any table or instance reaches it.
fn validate_abi_version(abi_version: unsafe extern "C" fn() -> u32) -> Result<(), ScriptLoadError> {
    // SAFETY: a constant-returning function exported by the freshly loaded,
    // still-mapped library.
    let found = unsafe { abi_version() };
    if found == ABI_VERSION {
        Ok(())
    } else {
        Err(ScriptLoadError::AbiVersionMismatch {
            found,
            expected: ABI_VERSION,
        })
    }
}

fn symbol<T: Copy>(handle: LibraryHandle, name: &str) -> Option<T> {
    let pointer = lookup_symbol(handle, name);
    if pointer.is_null() {
        return None;
    }
    if core::mem::size_of::<T>() != core::mem::size_of_val(&pointer) {
        return None;
    }
    // SAFETY: each call specifies the exported function's exact ABI signature;
    // the size check ensures transmute_copy reads only the pointer-sized value.
    Some(unsafe { core::mem::transmute_copy::<*mut core::ffi::c_void, T>(&pointer) })
}

#[cfg(unix)]
fn open_library(path: &str) -> Result<LibraryHandle, ScriptLoadError> {
    let Ok(path) = CString::new(path) else {
        return Err(ScriptLoadError::DlopenFailed(
            "library path contains an interior NUL byte".into(),
        ));
    };
    // SAFETY: the path is a valid NUL-terminated string for the call.
    let handle = unsafe { libc::dlopen(path.as_ptr(), libc::RTLD_NOW) };
    if handle.is_null() {
        // SAFETY: dlerror's message stays valid until the next dlopen/dlerror
        // call, none of which happens before it is copied below.
        let message = unsafe { libc::dlerror() };
        let detail = if message.is_null() {
            "unknown dlopen error".to_string()
        } else {
            // SAFETY: a non-null dlerror result is NUL-terminated.
            unsafe { CStr::from_ptr(message.cast::<c_char>()) }
                .to_string_lossy()
                .into_owned()
        };
        return Err(ScriptLoadError::DlopenFailed(detail));
    }
    Ok(handle)
}

#[cfg(windows)]
fn open_library(path: &str) -> Result<LibraryHandle, ScriptLoadError> {
    let mut encoded: Vec<u16> = path.encode_utf16().collect();
    if encoded.contains(&0) {
        return Err(ScriptLoadError::DlopenFailed(
            "library path contains an interior NUL character".into(),
        ));
    }
    encoded.push(0);
    // SAFETY: `encoded` is a NUL-terminated UTF-16 range for the call.
    let module = unsafe { win32::LoadLibraryW(encoded.as_ptr()) };
    if module.is_null() {
        // SAFETY: GetLastError reads this thread's last Win32 error code.
        let code = unsafe { win32::GetLastError() };
        return Err(ScriptLoadError::DlopenFailed(format!(
            "LoadLibraryW failed (os error {code})"
        )));
    }
    Ok(module)
}

#[cfg(not(any(unix, windows)))]
fn open_library(_path: &str) -> Result<LibraryHandle, ScriptLoadError> {
    Err(ScriptLoadError::UnsupportedPlatform)
}

#[cfg(unix)]
fn lookup_symbol(handle: LibraryHandle, name: &str) -> *mut core::ffi::c_void {
    let Ok(symbol) = CString::new(name) else {
        return core::ptr::null_mut();
    };
    // SAFETY: the handle is a live dlopen handle and the symbol name is a
    // NUL-terminated string for the call.
    unsafe { libc::dlsym(handle, symbol.as_ptr()) }
}

#[cfg(windows)]
fn lookup_symbol(handle: LibraryHandle, name: &str) -> *mut core::ffi::c_void {
    let Ok(symbol) = CString::new(name) else {
        return core::ptr::null_mut();
    };
    // SAFETY: the module handle is live and the name is NUL-terminated ASCII.
    // `c_char` is signed on MSVC targets, so the declaration's `u8` parameter
    // receives an explicit cast.
    let function = unsafe { win32::GetProcAddress(handle, symbol.as_ptr().cast::<u8>()) };
    match function {
        Some(function) => function as *mut core::ffi::c_void,
        None => core::ptr::null_mut(),
    }
}

#[cfg(not(any(unix, windows)))]
fn lookup_symbol(_handle: LibraryHandle, _name: &str) -> *mut core::ffi::c_void {
    core::ptr::null_mut()
}

/// Minimal Win32 loader declarations. `FreeLibrary` is deliberately absent:
/// images are never unmapped (see [`LoadedLibrary`]).
#[cfg(windows)]
mod win32 {
    use core::ffi::c_void;

    pub type HMODULE = *mut c_void;
    pub type FARPROC = Option<unsafe extern "system" fn() -> isize>;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        pub fn LoadLibraryW(lp_lib_file_name: *const u16) -> HMODULE;
        pub fn GetProcAddress(h_module: HMODULE, lp_proc_name: *const u8) -> FARPROC;
        pub fn GetLastError() -> u32;
    }
}
