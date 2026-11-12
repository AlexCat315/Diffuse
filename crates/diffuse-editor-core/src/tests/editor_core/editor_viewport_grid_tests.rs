//! Ported from `Editor/Tests/EditorCoreTests/EditorViewportGridTests.swift`.
//!
//! `presentationBackdrop` is blocked: it needs the unmigrated
//! `EditorApplication` shell (`EditorApplication(projectDirectory:seedPreviewScene:)`,
//! `makeViewportRenderSettings(shadowsEnabled:shadingMode:)`, `store.dispatch`) and
//! the viewport render settings/backdrop types it returns. Only the grid-state
//! case is translated below.

/// The grid defaults on, toggles through the reducer, and restores from state,
/// including files that predate the field.
#[test]
fn grid_state_persists() {
    use crate::state::editor_reducer::{EditorAction, EditorReducer};
    use crate::state::editor_state::EditorState;

    let mut state = EditorState::new();
    assert!(state.viewport.grid_enabled);
    EditorReducer::reduce(&mut state, EditorAction::SetViewportGridEnabled(false));
    assert!(!state.viewport.grid_enabled);

    let data = serde_json::to_vec(&state).expect("encode editor state");
    let restored: EditorState = serde_json::from_slice(&data).expect("decode editor state");
    assert!(!restored.viewport.grid_enabled);

    let mut object: serde_json::Value =
        serde_json::from_slice(&data).expect("decode editor state object");
    object["viewport"]
        .as_object_mut()
        .expect("viewport object")
        .remove("gridEnabled");
    let missing_field_data = serde_json::to_vec(&object).expect("encode legacy editor state");
    let legacy: EditorState =
        serde_json::from_slice(&missing_field_data).expect("decode legacy editor state");
    assert!(legacy.viewport.grid_enabled);
}
