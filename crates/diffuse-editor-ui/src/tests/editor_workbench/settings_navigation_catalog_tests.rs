//! Ported from `Editor/Tests/EditorWorkbenchTests/SettingsWorkflowTests.swift`
//! (search and category coverage cases).

use std::collections::BTreeSet;

use crate::settings::navigation_catalog::{SettingsCategory, SettingsSectionID};

/// Settings search matches localized titles and keywords together.
#[test]
fn section_search() {
    assert_eq!(
        SettingsSectionID::visible(SettingsCategory::General, "密钥", true),
        [SettingsSectionID::Provider]
    );
    assert_eq!(
        SettingsSectionID::visible(SettingsCategory::Editor, "openai model", true),
        [SettingsSectionID::Provider]
    );
    assert_eq!(
        SettingsSectionID::visible(SettingsCategory::Assistant, "vsync", true),
        [SettingsSectionID::Display]
    );
    assert_eq!(
        SettingsSectionID::visible(SettingsCategory::General, " ", true),
        [SettingsSectionID::Appearance, SettingsSectionID::Language]
    );
    assert!(
        SettingsSectionID::visible(SettingsCategory::General, "no-such-preference", true)
            .is_empty()
    );
}

/// Every category owns at least one section.
#[test]
fn category_coverage() {
    let categories: BTreeSet<SettingsCategory> = SettingsSectionID::ALL
        .iter()
        .map(|section| section.category())
        .collect();
    assert_eq!(
        categories,
        SettingsCategory::ALL.into_iter().collect::<BTreeSet<_>>()
    );
}

/// Hiding the assistant removes its sections from browse and search.
#[test]
fn agent_sections_hidden_without_agent() {
    assert!(SettingsSectionID::visible(SettingsCategory::Assistant, "", false).is_empty());
    assert_eq!(
        SettingsSectionID::visible(SettingsCategory::Assistant, "", true),
        [
            SettingsSectionID::Provider,
            SettingsSectionID::Execution,
            SettingsSectionID::Capabilities
        ]
    );
}
