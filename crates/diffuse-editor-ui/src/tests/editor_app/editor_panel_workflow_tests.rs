//! Ported from `Editor/Tests/EditorAppTests/EditorPanelWorkflowTests.swift`.
//!
//! The asset browser selection cases run against the migrated
//! `AssetBrowserSelectionModel`. The remaining 15 cases stay blocked on empty
//! production placeholders: `HierarchyPanelModel` (`hierarchy_panel_model.rs`),
//! `ConsoleEntryFilter`/`ConsoleEntryExport`/`ConsoleScrollGeometry`
//! (`console/console_panel.rs`), `InspectorSectionFilter`/`InspectorComponentFilter`
//! (`inspector/inspector_panel.rs`, `inspector/component_menu.rs`),
//! `EditorAISettingsDraft`, `AssetBrowserOrdering` and `AssetFolderListing`
//! (`asset_browser/asset_browser_panel.rs`).

use crate::panels::asset_browser::asset_browser_selection::AssetBrowserSelectionModel;

fn selected_ids(selection: &AssetBrowserSelectionModel) -> Vec<String> {
    selection.selected_ids().iter().cloned().collect()
}

/// Asset browser selection supports range and modifier toggles.
#[test]
fn asset_browser_selection() {
    use diffuse_kernel::input_event::KeyModifiers;

    let visible_ids: Vec<String> = ["a", "b", "c", "d", "e"]
        .into_iter()
        .map(str::to_owned)
        .collect();
    let mut selection = AssetBrowserSelectionModel::new();

    selection.select("b", &visible_ids, KeyModifiers::default());
    selection.select("d", &visible_ids, KeyModifiers::LEFT_SHIFT);
    assert_eq!(selected_ids(&selection), ["b", "c", "d"]);

    selection.select("c", &visible_ids, KeyModifiers::LEFT_GUI);
    assert_eq!(selected_ids(&selection), ["b", "d"]);

    selection.select(
        "e",
        &visible_ids,
        KeyModifiers::LEFT_GUI | KeyModifiers::LEFT_SHIFT,
    );
    assert_eq!(selected_ids(&selection), ["b", "c", "d", "e"]);
    selection.select_all(&["a".to_owned(), "e".to_owned()]);
    assert_eq!(selected_ids(&selection), ["a", "e"]);
    selection.clear();
    assert!(selection.selected_ids().is_empty());
}

/// Asset browser keyboard navigation stays within visible results.
#[test]
fn asset_browser_keyboard_navigation() {
    let visible_ids: Vec<String> = ["a", "b", "c"].into_iter().map(str::to_owned).collect();
    assert_eq!(
        AssetBrowserSelectionModel::adjacent_asset_id(None, &visible_ids, 1),
        Some("a".to_owned())
    );
    assert_eq!(
        AssetBrowserSelectionModel::adjacent_asset_id(Some("b"), &visible_ids, -1),
        Some("a".to_owned())
    );
    assert_eq!(
        AssetBrowserSelectionModel::adjacent_asset_id(Some("c"), &visible_ids, 1),
        None
    );
    assert_eq!(
        AssetBrowserSelectionModel::adjacent_asset_id(None, &visible_ids, -1),
        Some("c".to_owned())
    );
}
