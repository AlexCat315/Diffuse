//! The C ABI engine scripts are compiled against.
//!
//! MIGRATION.md §4 D1: Swift scripts called back into the engine through
//! `@_cdecl("cove_*")` symbols plus a `ScriptContext` Swift object. Rust has no
//! stable ABI, so every capability a script may reach crosses this table
//! instead. The layout is `#[repr(C)]` and versioned; the host refuses to load a
//! library whose `abi_version` differs.

use core::ffi::{c_char, c_void};

/// ABI version. Bumping this makes the host reject older script libraries.
pub const ABI_VERSION: u32 = 1;

/// A borrowed UTF-8 byte range. Empty ranges may carry a null pointer.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Slice {
    pub ptr: *const u8,
    pub len: usize,
}

impl Slice {
    pub const EMPTY: Slice = Slice {
        ptr: core::ptr::null(),
        len: 0,
    };

    #[inline]
    pub fn as_str(&self) -> Option<&str> {
        if self.len == 0 {
            return Some("");
        }
        if self.ptr.is_null() {
            return None;
        }
        // SAFETY: the host owns these bytes for the duration of the callback, and
        // `Slice::as_str` callers only read within that window.
        let bytes = unsafe { core::slice::from_raw_parts(self.ptr, self.len) };
        core::str::from_utf8(bytes).ok()
    }
}

impl Default for Slice {
    fn default() -> Self {
        Slice::EMPTY
    }
}

/// An owned byte range the host frees with [`HostApi::free`], or a borrowed one
/// the script must not free (`owned == false`).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Bytes {
    pub ptr: *mut u8,
    pub len: usize,
    pub owned: bool,
}

impl Bytes {
    pub const EMPTY: Bytes = Bytes {
        ptr: core::ptr::null_mut(),
        len: 0,
        owned: false,
    };

    #[inline]
    pub fn as_slice(&self) -> &[u8] {
        if self.len == 0 || self.ptr.is_null() {
            return &[];
        }
        // SAFETY: the host owns these bytes for the duration of the callback.
        unsafe { core::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Default for Bytes {
    fn default() -> Self {
        Bytes::EMPTY
    }
}

/// `Transform3D` in the engine's layout: `SIMD3<Float>` is 16 bytes/16-aligned
/// (`.migration/simd-layout.json`), so this is 48 bytes with no padding.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Transform3 {
    pub translation: [f32; 4],
    pub rotation: [f32; 4],
    pub scale: [f32; 4],
}

const _: () = assert!(core::mem::size_of::<Transform3>() == 48);
const _: () = assert!(core::mem::align_of::<Transform3>() == 16);
const _: () = assert!(core::mem::size_of::<Slice>() == 2 * core::mem::size_of::<usize>());

impl Transform3 {
    #[inline]
    pub const fn new(translation: [f32; 4], rotation: [f32; 4], scale: [f32; 4]) -> Self {
        Transform3 {
            translation,
            rotation,
            scale,
        }
    }
}

/// Character ground state, matching Swift's `CharacterGroundState` raw values.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GroundState {
    OnGround = 0,
    OnSteepGround = 1,
    NotSupported = 2,
    InAir = 3,
    /// What the Swift bridge returned when no character state was available.
    Unavailable = 0xFF,
}

impl GroundState {
    pub const fn from_raw(value: u8) -> GroundState {
        match value {
            0 => GroundState::OnGround,
            1 => GroundState::OnSteepGround,
            2 => GroundState::NotSupported,
            3 => GroundState::InAir,
            _ => GroundState::Unavailable,
        }
    }
}

/// Character stance, matching Swift's `CharacterStance` raw values.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CharacterStance {
    Standing = 0,
    Crouching = 1,
}

/// The engine-provided function table. The host fills every entry before any
/// lifecycle callback runs; a null entry means "unsupported in this host" and
/// the safe wrappers fall back to the Swift defaults (0 / false / no-op).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HostApi {
    pub abi_version: u32,

    /// Opaque handle for the currently running script instance.
    pub instance: *mut c_void,

    // ---- timing -----------------------------------------------------------
    /// `cove_delta_time` / `ScriptContext.deltaTime`.
    pub delta_time: Option<extern "C" fn(instance: *mut c_void) -> f64>,

    // ---- input ------------------------------------------------------------
    /// `cove_input_axis`.
    pub input_axis: Option<extern "C" fn(instance: *mut c_void, name: Slice) -> f32>,
    /// `cove_input_held`.
    pub input_held: Option<extern "C" fn(instance: *mut c_void, name: Slice) -> bool>,
    /// `cove_input_just_pressed`.
    pub input_just_pressed: Option<extern "C" fn(instance: *mut c_void, name: Slice) -> bool>,
    /// `cove_input_just_released`.
    pub input_just_released: Option<extern "C" fn(instance: *mut c_void, name: Slice) -> bool>,

    // ---- identity ---------------------------------------------------------
    /// `ScriptContext.entity`.
    pub entity: Option<extern "C" fn(instance: *mut c_void) -> u64>,
    /// `ScriptContext.isAlive`.
    pub entity_is_alive: Option<extern "C" fn(instance: *mut c_void, entity: u64) -> bool>,

    // ---- entity lifecycle -------------------------------------------------
    /// `ScriptContext.createEntity(named:parent:)`.
    pub create_entity: Option<
        extern "C" fn(instance: *mut c_void, name: Slice, parent: u64, has_parent: bool) -> u64,
    >,
    /// `ScriptContext.destroyEntity(_:)`.
    pub destroy_entity: Option<extern "C" fn(instance: *mut c_void, entity: u64) -> bool>,
    /// `ScriptContext.setParent(_:for:)`.
    pub set_parent: Option<
        extern "C" fn(instance: *mut c_void, child: u64, parent: u64, has_parent: bool) -> bool,
    >,
    /// `ScriptContext.parent(of:)`.
    pub parent_of:
        Option<extern "C" fn(instance: *mut c_void, entity: u64, out_parent: *mut u64) -> bool>,
    /// `ScriptContext.entity(named:)`.
    pub entity_named: Option<extern "C" fn(instance: *mut c_void, name: Slice) -> u64>,

    // ---- transforms -------------------------------------------------------
    /// `ScriptContext.localTransform`.
    pub local_transform: Option<extern "C" fn(instance: *mut c_void) -> Transform3>,
    /// `ScriptContext.localTransform(of:)`.
    pub local_transform_of:
        Option<extern "C" fn(instance: *mut c_void, entity: u64, out: *mut Transform3) -> bool>,
    /// `ScriptContext.worldTransform`.
    pub world_transform: Option<extern "C" fn(instance: *mut c_void) -> Transform3>,
    /// `ScriptContext.worldTransform(of:)`.
    pub world_transform_of:
        Option<extern "C" fn(instance: *mut c_void, entity: u64, out: *mut Transform3) -> bool>,
    /// `ScriptContext.setLocalTransform(_:)`.
    pub set_local_transform:
        Option<extern "C" fn(instance: *mut c_void, value: Transform3) -> bool>,
    /// `ScriptContext.setLocalTransform(_:for:)`.
    pub set_local_transform_for:
        Option<extern "C" fn(instance: *mut c_void, value: Transform3, entity: u64) -> bool>,

    // ---- components -------------------------------------------------------
    /// `ScriptContext.component(_:)` with the component type name; writes JSON
    /// into `out` (host-allocated, freed by `free`).
    pub get_component:
        Option<extern "C" fn(instance: *mut c_void, entity: u64, type_name: Slice) -> Bytes>,
    /// `ScriptContext.hasComponent(_:)`.
    pub has_component:
        Option<extern "C" fn(instance: *mut c_void, entity: u64, type_name: Slice) -> bool>,
    /// `ScriptContext.setComponent(_:)` from component JSON.
    pub set_component: Option<
        extern "C" fn(instance: *mut c_void, entity: u64, type_name: Slice, json: Slice) -> bool,
    >,
    /// `ScriptContext.removeComponent(_:)`.
    pub remove_component:
        Option<extern "C" fn(instance: *mut c_void, entity: u64, type_name: Slice) -> bool>,

    // ---- parameters -------------------------------------------------------
    /// The binding's parameter JSON for this invocation.
    pub parameters_json: Option<extern "C" fn(instance: *mut c_void) -> Bytes>,
    /// `ScriptContext.floatParameter(_:)`.
    pub float_parameter:
        Option<extern "C" fn(instance: *mut c_void, name: Slice, out: *mut f32) -> bool>,
    /// `ScriptContext.doubleParameter(_:)`.
    pub double_parameter:
        Option<extern "C" fn(instance: *mut c_void, name: Slice, out: *mut f64) -> bool>,
    /// `ScriptContext.stringParameter(_:)`.
    pub string_parameter: Option<extern "C" fn(instance: *mut c_void, name: Slice) -> Bytes>,
    /// `ScriptContext.vector3Parameter(_:)`.
    pub vector3_parameter:
        Option<extern "C" fn(instance: *mut c_void, name: Slice, out: *mut [f32; 4]) -> bool>,
    /// `ScriptContext.entityParameter(_:)`.
    pub entity_parameter:
        Option<extern "C" fn(instance: *mut c_void, name: Slice, out: *mut u64) -> bool>,

    // ---- resources --------------------------------------------------------
    /// `ScriptContext.resource(_:)` with the resource type name, as JSON.
    pub get_resource: Option<extern "C" fn(instance: *mut c_void, type_name: Slice) -> Bytes>,
    /// `ScriptContext.setResource(_:)` from resource JSON.
    pub set_resource:
        Option<extern "C" fn(instance: *mut c_void, type_name: Slice, json: Slice) -> bool>,
    /// `ScriptContext.removeResource(_:)`.
    pub remove_resource: Option<extern "C" fn(instance: *mut c_void, type_name: Slice) -> bool>,

    // ---- UI and state -----------------------------------------------------
    /// `ScriptContext.drawUI(_:)`: a label command.
    pub draw_label: Option<
        extern "C" fn(
            instance: *mut c_void,
            text: Slice,
            x: f32,
            y: f32,
            font_size: f32,
            color: [f32; 4],
        ),
    >,
    /// `ScriptContext.drawUI(_:)`: a rect command.
    pub draw_rect: Option<
        extern "C" fn(
            instance: *mut c_void,
            x: f32,
            y: f32,
            w: f32,
            h: f32,
            corner_radius: f32,
            color: [f32; 4],
        ),
    >,
    /// `ScriptContext.drawUI(_:)`: a progress bar command.
    #[allow(clippy::type_complexity)]
    pub draw_progress_bar: Option<
        extern "C" fn(
            instance: *mut c_void,
            x: f32,
            y: f32,
            w: f32,
            h: f32,
            value: f32,
            max_value: f32,
            corner_radius: f32,
            fill_color: [f32; 4],
            bg_color: [f32; 4],
        ),
    >,
    /// `ScriptContext.reportState`: a JSON state blob handed to the editor.
    pub report_state: Option<extern "C" fn(instance: *mut c_void, json: Slice)>,

    // ---- character controller --------------------------------------------
    /// `cove_submit_character_command`.
    pub submit_character_command: Option<
        extern "C" fn(
            instance: *mut c_void,
            vx: f32,
            vy: f32,
            vz: f32,
            jump: bool,
            jump_speed: f32,
            stance: u8,
        ),
    >,
    /// `cove_character_is_grounded`.
    pub character_is_grounded: Option<extern "C" fn(instance: *mut c_void) -> bool>,
    /// `cove_character_ground_state`.
    pub character_ground_state: Option<extern "C" fn(instance: *mut c_void) -> u8>,
    /// `cove_character_velocity`.
    pub character_velocity: Option<extern "C" fn(instance: *mut c_void, out: *mut [f32; 3])>,

    // ---- allocation -------------------------------------------------------
    /// Frees a `Bytes` the host allocated for this script.
    pub free: Option<extern "C" fn(bytes: Bytes)>,
}

const _: () =
    assert!(core::mem::size_of::<HostApi>().is_multiple_of(core::mem::align_of::<usize>()));

impl HostApi {
    /// A table whose entries are all null; the host fills in what it supports.
    pub const fn empty() -> HostApi {
        HostApi {
            abi_version: ABI_VERSION,
            instance: core::ptr::null_mut(),
            delta_time: None,
            input_axis: None,
            input_held: None,
            input_just_pressed: None,
            input_just_released: None,
            entity: None,
            entity_is_alive: None,
            create_entity: None,
            destroy_entity: None,
            set_parent: None,
            parent_of: None,
            entity_named: None,
            local_transform: None,
            local_transform_of: None,
            world_transform: None,
            world_transform_of: None,
            set_local_transform: None,
            set_local_transform_for: None,
            get_component: None,
            has_component: None,
            set_component: None,
            remove_component: None,
            parameters_json: None,
            float_parameter: None,
            double_parameter: None,
            string_parameter: None,
            vector3_parameter: None,
            entity_parameter: None,
            get_resource: None,
            set_resource: None,
            remove_resource: None,
            draw_label: None,
            draw_rect: None,
            draw_progress_bar: None,
            report_state: None,
            submit_character_command: None,
            character_is_grounded: None,
            character_ground_state: None,
            character_velocity: None,
            free: None,
        }
    }

    /// The ABI version this table was built for.
    #[inline]
    pub const fn version(&self) -> u32 {
        self.abi_version
    }
}

impl Default for HostApi {
    fn default() -> Self {
        Self::empty()
    }
}

/// Converts a `&str` into a borrowed [`Slice`] for the duration of a call.
#[inline]
pub fn slice_of(value: &str) -> Slice {
    Slice {
        ptr: value.as_ptr(),
        len: value.len(),
    }
}

/// True when a C string pointer is null.
#[inline]
pub fn is_null(ptr: *const c_char) -> bool {
    ptr.is_null()
}
