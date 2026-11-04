//! ABI layout and safe-wrapper tests for `diffuse-script-api`.
//!
//! These are additive: MIGRATION.md §4 D1 defines this crate, so it has no Swift
//! test target of its own. They lock the layout promises the host relies on.

use diffuse_script_api::abi::{
    ABI_VERSION, Bytes, CharacterStance, GroundState, HostApi, Slice, Transform3,
};
use diffuse_script_api::authoring::json::{self, JsonValue};
use diffuse_script_api::authoring::{
    ScriptDefinition, ScriptDefinitionBuilder, ScriptParameters, ScriptProperty,
    ScriptPropertyOption, ScriptPropertyValue,
};
use diffuse_script_api::context::ScriptContext;

// ABI 3 carries the full matrix (including shear), with four aligned columns.
#[test]
fn transform3_layout_matches_swift() {
    assert_eq!(core::mem::size_of::<Transform3>(), 64);
    assert_eq!(core::mem::align_of::<Transform3>(), 16);
}

#[test]
fn slice_is_pointer_plus_length() {
    assert_eq!(
        core::mem::size_of::<Slice>(),
        2 * core::mem::size_of::<usize>()
    );
    // SAFETY: an empty range does not dereference its null pointer.
    assert_eq!(unsafe { Slice::EMPTY.as_str() }, Some(""));
    let sample = Slice {
        ptr: "hé".as_ptr(),
        len: "hé".len(),
    };
    // SAFETY: sample references a static UTF-8 literal for its exact byte length.
    assert_eq!(unsafe { sample.as_str() }, Some("hé"));
}

#[test]
fn abi_version_is_stable_and_reported() {
    assert_eq!(ABI_VERSION, 3);
    let table = HostApi::empty();
    assert_eq!(table.version(), ABI_VERSION);
    // SAFETY: entries are absent or static test hooks with no borrowed host state.
    let context = unsafe { ScriptContext::new(table) };
    assert!(context.is_compatible());
}

#[test]
fn ground_state_maps_swift_raw_values() {
    assert_eq!(GroundState::from_raw(0), GroundState::OnGround);
    assert_eq!(GroundState::from_raw(1), GroundState::OnSteepGround);
    assert_eq!(GroundState::from_raw(2), GroundState::NotSupported);
    assert_eq!(GroundState::from_raw(3), GroundState::InAir);
    assert_eq!(GroundState::from_raw(0xFF), GroundState::Unavailable);
    assert_eq!(GroundState::Unavailable as u8, 0xFF);
    assert_eq!(CharacterStance::Crouching as u8, 1);
}

// Swift's bridge returned 0 / false when there was no live context.
#[test]
fn absent_host_entries_keep_swift_fallbacks() {
    // SAFETY: an empty table has no callbacks or host allocation to invalidate.
    let context = unsafe { ScriptContext::new(HostApi::empty()) };
    assert_eq!(context.delta_time(), 0.0);
    assert_eq!(context.input_axis("move"), 0.0);
    assert!(!context.input_held("jump"));
    assert_eq!(context.entity(), 0);
    assert_eq!(context.create_entity(None, Transform3::IDENTITY), None);
    assert_eq!(context.parent(7), None);
    assert_eq!(context.float_parameter("speed"), None);
    assert_eq!(context.parameters_json(), "{}");
    assert_eq!(context.character_ground_state(), GroundState::Unavailable);
    assert_eq!(context.character_velocity(), [0.0, 0.0, 0.0]);
}

#[test]
fn bytes_round_trip_through_the_free_hook() {
    use std::sync::atomic::{AtomicUsize, Ordering};

    static FREED: AtomicUsize = AtomicUsize::new(0);
    extern "C" fn free(bytes: Bytes) {
        FREED.fetch_add(1, Ordering::SeqCst);
        if bytes.owned && !bytes.ptr.is_null() {
            // SAFETY: the table handed ownership of this allocation to the script,
            // which reclaims it exactly once here.
            unsafe {
                drop(Box::from_raw(core::ptr::slice_from_raw_parts_mut(
                    bytes.ptr, bytes.len,
                )));
            }
        }
    }

    let mut table = HostApi::empty();
    table.parameters_json = Some(parameters_json_stub);

    extern "C" fn parameters_json_stub(_instance: *mut core::ffi::c_void) -> Bytes {
        let data = b"{\"speed\":2.5}".to_vec().into_boxed_slice();
        Bytes {
            len: data.len(),
            ptr: Box::into_raw(data).cast(),
            owned: true,
        }
    }
    table.free = Some(free);

    // SAFETY: entries are absent or static test hooks with no borrowed host state.
    let context = unsafe { ScriptContext::new(table) };
    assert_eq!(context.parameters_json(), "{\"speed\":2.5}");
    assert_eq!(FREED.load(Ordering::SeqCst), 1);
}

#[test]
fn definition_resolution_applies_defaults_then_overrides() {
    let definition = ScriptDefinitionBuilder::new()
        .property("speed", ScriptPropertyValue::Number(1.0))
        .property("label", ScriptPropertyValue::String("hero".to_string()))
        .build();

    let resolved = ScriptParameters::resolve(&definition, "{}", "{\"speed\":3.5}");
    assert_eq!(resolved.values.get("speed"), Some(&JsonValue::Number(3.5)));
    assert_eq!(
        resolved.values.get("label"),
        Some(&JsonValue::String("hero".to_string()))
    );

    // An override of the wrong kind is ignored, matching Swift's guard.
    let rejected = ScriptParameters::resolve(&definition, "{}", "{\"speed\":\"fast\"}");
    assert_eq!(rejected.values.get("speed"), Some(&JsonValue::Number(1.0)));
}

#[test]
fn options_restrict_accepted_values() {
    let property = ScriptProperty::new("mode", ScriptPropertyValue::String("run".to_string()))
        .with_options(vec![
            ScriptPropertyOption::new("run", Some("Run".to_string())),
            ScriptPropertyOption::new("walk", Some("Walk".to_string())),
        ]);
    let definition = ScriptDefinition::new(vec![property]);

    let accepted = ScriptParameters::resolve(&definition, "{}", "{\"mode\":\"walk\"}");
    assert_eq!(
        accepted.values.get("mode"),
        Some(&JsonValue::String("walk".to_string()))
    );

    let rejected = ScriptParameters::resolve(&definition, "{}", "{\"mode\":\"fly\"}");
    assert_eq!(
        rejected.values.get("mode"),
        Some(&JsonValue::String("run".to_string()))
    );
}

#[test]
fn json_parser_matches_swift_sorted_key_output() {
    let values = json::parse_object("{\"z\":1,\"a\":[true,null,\"x\"],\"m\":{\"b\":2,\"a\":1}}");
    let round_trip = JsonValue::Object(values).to_json();
    assert_eq!(
        round_trip,
        "{\"a\":[true,null,\"x\"],\"m\":{\"a\":1,\"b\":2},\"z\":1}"
    );
}

#[test]
fn json_parser_handles_surrogate_pairs_and_escapes() {
    let values = json::parse_object("{\"text\":\"\\ud83d\\ude00 \\\"q\\\"\"}");
    assert_eq!(
        values.get("text"),
        Some(&JsonValue::String("😀 \"q\"".to_string()))
    );
    assert!(json::parse_object("not json").is_empty());
}

mod ffi_regressions {
    use super::*;
    use core::ffi::c_void;
    use diffuse_script_api::abi::slice_of;
    use diffuse_script_api::authoring::{ScriptAuthoring, ScriptBehavior};
    use std::cell::Cell;
    use std::sync::{
        OnceLock,
        atomic::{AtomicUsize, Ordering},
    };

    thread_local! { static ALLOCATIONS: Cell<(usize, usize)> = const { Cell::new((0, 0)) }; }
    static PANIC_DROPS: AtomicUsize = AtomicUsize::new(0);

    struct TestHost {
        errors: Vec<String>,
        reports: Vec<String>,
        matrix: Transform3,
        created_names: Vec<Option<String>>,
        parents: Vec<Option<u64>>,
    }
    impl Default for TestHost {
        fn default() -> Self {
            Self {
                errors: Vec::new(),
                reports: Vec::new(),
                matrix: Transform3::IDENTITY,
                created_names: Vec::new(),
                parents: Vec::new(),
            }
        }
    }
    extern "C" fn allocate(length: usize) -> Bytes {
        ALLOCATIONS.with(|counts| {
            let (a, f) = counts.get();
            counts.set((a + 1, f));
        });
        let data = vec![0_u8; length].into_boxed_slice();
        Bytes {
            ptr: Box::into_raw(data).cast(),
            len: length,
            owned: true,
        }
    }
    extern "C" fn free(bytes: Bytes) {
        if bytes.owned && !bytes.ptr.is_null() {
            ALLOCATIONS.with(|counts| {
                let (a, f) = counts.get();
                counts.set((a, f + 1));
            });
            // SAFETY: this fixture frees exactly the boxed range returned by allocate.
            drop(unsafe {
                Box::from_raw(core::ptr::slice_from_raw_parts_mut(bytes.ptr, bytes.len))
            });
        }
    }
    extern "C" fn report_error(instance: *mut c_void, text: Slice) {
        // SAFETY: each test retains its boxed TestHost through every SDK call and final destruction.
        let state = unsafe { &mut *instance.cast::<TestHost>() };
        // SAFETY: SDK report strings remain live for this callback and are copied immediately.
        state
            .errors
            .push(unsafe { text.as_str() }.expect("report UTF-8").to_owned());
    }
    extern "C" fn report_state(instance: *mut c_void, text: Slice) {
        // SAFETY: the live boxed TestHost is exclusively accessed in this synchronous callback.
        let state = unsafe { &mut *instance.cast::<TestHost>() };
        // SAFETY: SDK state strings remain live for this callback and are copied immediately.
        state
            .reports
            .push(unsafe { text.as_str() }.expect("state UTF-8").to_owned());
    }
    fn host(state: &mut TestHost) -> HostApi {
        let mut table = HostApi::empty();
        table.instance = (state as *mut TestHost).cast();
        table.allocate = Some(allocate);
        table.free = Some(free);
        table.report_error = Some(report_error);
        table.report_state = Some(report_state);
        table
    }

    #[derive(Default)]
    struct AuthoredScript;
    impl ScriptBehavior for AuthoredScript {
        fn on_start(&mut self, context: &ScriptContext) {
            context.report_state("{\"started\":true}");
        }
    }
    impl ScriptAuthoring for AuthoredScript {
        fn definition() -> &'static ScriptDefinition {
            static DEFINITION: OnceLock<ScriptDefinition> = OnceLock::new();
            DEFINITION.get_or_init(|| {
                ScriptDefinitionBuilder::new()
                    .property("speed", ScriptPropertyValue::Number(2.0))
                    .build()
            })
        }
    }
    #[derive(Default)]
    struct PanickingScript;
    impl ScriptBehavior for PanickingScript {
        fn on_update(&mut self, context: &ScriptContext) {
            context.report_state("{\"updated\":true}");
            panic!("fixture lifecycle panic");
        }
    }
    impl Drop for PanickingScript {
        fn drop(&mut self) {
            PANIC_DROPS.fetch_add(1, Ordering::SeqCst);
        }
    }
    diffuse_script_api::diffuse_scripts!(AuthoredScript, PanickingScript);

    #[test]
    fn full_matrix_crosses_host_callbacks_without_losing_shear() {
        extern "C" fn set(instance: *mut c_void, value: Transform3) -> bool {
            // SAFETY: host owns the boxed TestHost and serializes these test callbacks.
            unsafe { &mut *instance.cast::<TestHost>() }.matrix = value;
            true
        }
        extern "C" fn get(instance: *mut c_void, out: *mut Transform3) -> bool {
            // SAFETY: fixture host is live; the SDK wrapper supplies an aligned output value.
            unsafe {
                out.write((*instance.cast::<TestHost>()).matrix);
            }
            true
        }
        let mut state = Box::<TestHost>::default();
        let mut table = host(&mut state);
        table.set_local_transform = Some(set);
        table.local_transform = Some(get);
        // SAFETY: table hooks and boxed state outlive this context.
        let context = unsafe { ScriptContext::new(table) };
        let mut matrix = Transform3::IDENTITY;
        matrix.columns[1][0] = 0.375;
        matrix.columns[2][1] = -0.25;
        matrix.columns[3] = [4.0, -2.0, 9.0, 1.0];
        assert!(context.set_local_transform(matrix));
        assert_eq!(context.local_transform(), Some(matrix));
    }

    #[test]
    fn empty_owned_strings_are_present_and_freed_once() {
        extern "C" fn empty(_instance: *mut c_void, _name: Slice) -> Bytes {
            allocate(0)
        }
        let mut state = Box::<TestHost>::default();
        let mut table = host(&mut state);
        table.string_parameter = Some(empty);
        ALLOCATIONS.with(|counts| counts.set((0, 0)));
        // SAFETY: table hooks and boxed state outlive this context.
        let context = unsafe { ScriptContext::new(table) };
        assert_eq!(context.string_parameter("label"), Some(String::new()));
        assert_eq!(ALLOCATIONS.with(Cell::get), (1, 1));
    }

    #[test]
    fn entity_zero_empty_name_and_missing_name_remain_distinct() {
        extern "C" fn create(
            instance: *mut c_void,
            name: Slice,
            has_name: bool,
            _matrix: Transform3,
            out: *mut u64,
        ) -> bool {
            // SAFETY: the live fixture state is exclusively borrowed for this callback.
            let state = unsafe { &mut *instance.cast::<TestHost>() };
            // SAFETY: a present name is borrowed from the SDK caller for this invocation.
            let name = has_name.then(|| unsafe { name.as_str() }.expect("name UTF-8").to_owned());
            state.created_names.push(name);
            // SAFETY: SDK create_entity supplies a live, aligned output value.
            unsafe {
                out.write(0);
            }
            true
        }
        extern "C" fn parent(
            instance: *mut c_void,
            _child: u64,
            parent: u64,
            has_parent: bool,
        ) -> bool {
            // SAFETY: the live fixture state is exclusively borrowed for this callback.
            unsafe { &mut *instance.cast::<TestHost>() }
                .parents
                .push(has_parent.then_some(parent));
            true
        }
        let mut state = Box::<TestHost>::default();
        let mut table = host(&mut state);
        table.create_entity = Some(create);
        table.set_parent = Some(parent);
        // SAFETY: table hooks and boxed state outlive this context.
        let context = unsafe { ScriptContext::new(table) };
        assert_eq!(context.create_entity(None, Transform3::IDENTITY), Some(0));
        assert_eq!(
            context.create_entity(Some(""), Transform3::IDENTITY),
            Some(0)
        );
        assert!(context.set_parent(7, None));
        assert!(context.set_parent(7, Some(0)));
        assert_eq!(state.created_names, [None, Some(String::new())]);
        assert_eq!(state.parents, [None, Some(0)]);
    }

    #[test]
    fn macro_catalog_preserves_authoring_and_host_allocation_ownership() {
        let mut state = Box::<TestHost>::default();
        let table = host(&mut state);
        ALLOCATIONS.with(|counts| counts.set((0, 0)));
        // SAFETY: host allocation hooks and state stay live until the buffer is released below.
        let bytes = unsafe { diffuse_script_catalog(&table) };
        assert!(bytes.owned && !bytes.ptr.is_null());
        // SAFETY: catalog returns a host-owned initialized buffer of this exact length.
        let text = core::str::from_utf8(unsafe { bytes.as_slice() }).expect("catalog UTF-8");
        let entries = json::parse(text).expect("catalog JSON");
        let entries = entries.as_array().expect("catalog array");
        assert_eq!(entries.len(), 2);
        let authored = entries[0].as_object().expect("authored catalog entry");
        assert_eq!(
            authored.get("name").and_then(JsonValue::as_str),
            Some("AuthoredScript")
        );
        let properties = authored["definition"].as_object().expect("definition")["properties"]
            .as_array()
            .expect("properties");
        assert_eq!(properties.len(), 1);
        let property = properties[0].as_object().expect("property");
        assert_eq!(
            property.get("key").and_then(JsonValue::as_str),
            Some("speed")
        );
        let value = property["defaultValue"]
            .as_object()
            .expect("associated enum")["number"]
            .as_object()
            .expect("number payload")["_0"]
            .as_f64();
        assert_eq!(value, Some(2.0));
        let fallback = entries[1].as_object().expect("un-authored entry")["definition"]
            .as_object()
            .expect("definition")["properties"]
            .as_array()
            .expect("empty properties");
        assert!(fallback.is_empty());
        free(bytes);
        assert_eq!(ALLOCATIONS.with(Cell::get), (1, 1));
        assert!(state.errors.is_empty());
    }

    #[test]
    fn lifecycle_panic_is_reported_once_and_disables_the_instance() {
        let mut state = Box::<TestHost>::default();
        let table = host(&mut state);
        PANIC_DROPS.store(0, Ordering::SeqCst);
        // SAFETY: fixture name and host are live, and the boxed host outlives instance destruction.
        let instance = unsafe { diffuse_script_create(slice_of("PanickingScript"), &table) };
        assert!(!instance.is_null());
        // SAFETY: calls are serialized on this live SDK instance and its owning host.
        assert_ne!(unsafe { diffuse_script_on_update(instance, &table) }, 0);
        assert_eq!(state.reports, ["{\"updated\":true}"]);
        assert_eq!(state.errors.len(), 1);
        assert!(state.errors[0].contains("fixture lifecycle panic"));
        // SAFETY: the instance remains live but disabled after its panic.
        assert_ne!(unsafe { diffuse_script_on_update(instance, &table) }, 0);
        assert_eq!(state.reports.len(), 1);
        assert_eq!(state.errors.len(), 1);
        // SAFETY: final ownership is returned exactly once while its host is still live.
        unsafe {
            diffuse_script_destroy(instance);
        }
        assert_eq!(PANIC_DROPS.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn invalid_abi_is_rejected_before_allocation_or_creation() {
        let mut state = Box::<TestHost>::default();
        let mut table = host(&mut state);
        table.abi_version = ABI_VERSION + 1;
        ALLOCATIONS.with(|counts| counts.set((0, 0)));
        // SAFETY: a complete readable table is supplied even though its header version differs.
        let instance = unsafe { diffuse_script_create(slice_of("AuthoredScript"), &table) };
        assert!(instance.is_null());
        // SAFETY: the mismatched table header remains live and readable.
        let bytes = unsafe { diffuse_script_catalog(&table) };
        assert!(bytes.ptr.is_null());
        assert_eq!(ALLOCATIONS.with(Cell::get), (0, 0));
    }

    #[test]
    fn unknown_script_returns_a_reported_creation_failure() {
        let mut state = Box::<TestHost>::default();
        let table = host(&mut state);
        // SAFETY: the complete fixture host and static name stay live for this call.
        let instance = unsafe { diffuse_script_create(slice_of("Missing"), &table) };
        assert!(instance.is_null());
        assert_eq!(state.errors.len(), 1);
        assert!(state.errors[0].contains("Unknown script 'Missing'"));
    }
}
