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

// Layout: MIGRATION.md §5.3 — SIMD3<Float> is 16 bytes, so Transform3 is 48.
#[test]
fn transform3_layout_matches_swift() {
    assert_eq!(core::mem::size_of::<Transform3>(), 48);
    assert_eq!(core::mem::align_of::<Transform3>(), 16);
}

#[test]
fn slice_is_pointer_plus_length() {
    assert_eq!(
        core::mem::size_of::<Slice>(),
        2 * core::mem::size_of::<usize>()
    );
    assert_eq!(Slice::EMPTY.as_str(), Some(""));
    let sample = Slice {
        ptr: "hé".as_ptr(),
        len: "hé".len(),
    };
    assert_eq!(sample.as_str(), Some("hé"));
}

#[test]
fn abi_version_is_stable_and_reported() {
    assert_eq!(ABI_VERSION, 3);
    let table = HostApi::empty();
    assert_eq!(table.version(), ABI_VERSION);
    let context = ScriptContext::new(table);
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
    let context = ScriptContext::new(HostApi::empty());
    assert_eq!(context.delta_time(), 0.0);
    assert_eq!(context.input_axis("move"), 0.0);
    assert!(!context.input_held("jump"));
    assert_eq!(context.entity(), 0);
    assert_eq!(context.create_entity(None, None), None);
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
        if !bytes.ptr.is_null() {
            // SAFETY: the table handed ownership of this allocation to the script,
            // which reclaims it exactly once here.
            unsafe {
                drop(Vec::from_raw_parts(bytes.ptr, bytes.len, bytes.len));
            }
        }
    }

    let mut table = HostApi::empty();
    table.parameters_json = Some(parameters_json_stub);

    extern "C" fn parameters_json_stub(_instance: *mut core::ffi::c_void) -> Bytes {
        let mut data = b"{\"speed\":2.5}".to_vec();
        let slice = Bytes {
            ptr: data.as_mut_ptr(),
            len: data.len(),
            owned: true,
        };
        core::mem::forget(data);
        slice
    }
    table.free = Some(free);

    let context = ScriptContext::new(table);
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
            ScriptPropertyOption::new("Run", ScriptPropertyValue::String("run".to_string())),
            ScriptPropertyOption::new("Walk", ScriptPropertyValue::String("walk".to_string())),
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
