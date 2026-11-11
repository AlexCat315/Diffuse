//! `Editor/Sources/EditorCore/Contributions/Categories.swift` — facets derived
//! from contribution points, never an exclusive package kind.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum PluginCategory {
    #[serde(rename = "Themes")]
    Themes,
    #[serde(rename = "Languages")]
    Languages,
    #[serde(rename = "AI")]
    Ai,
    #[serde(rename = "UI")]
    Ui,
    #[serde(rename = "Version Control")]
    VersionControl,
    #[serde(rename = "Tasks")]
    Tasks,
    #[serde(rename = "Other")]
    Other,
}

impl PluginCategory {
    /// Swift's `CaseIterable` order.
    pub const ALL: [PluginCategory; 7] = [
        PluginCategory::Themes,
        PluginCategory::Languages,
        PluginCategory::Ai,
        PluginCategory::Ui,
        PluginCategory::VersionControl,
        PluginCategory::Tasks,
        PluginCategory::Other,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            PluginCategory::Themes => "Themes",
            PluginCategory::Languages => "Languages",
            PluginCategory::Ai => "AI",
            PluginCategory::Ui => "UI",
            PluginCategory::VersionControl => "Version Control",
            PluginCategory::Tasks => "Tasks",
            PluginCategory::Other => "Other",
        }
    }

    pub(crate) fn categories(points: &[String], has_capabilities: bool) -> Vec<PluginCategory> {
        let mut found: BTreeSet<PluginCategory> = BTreeSet::new();
        for point in points {
            if point.starts_with("cove.theme/") {
                found.insert(PluginCategory::Themes);
            } else if point.starts_with("cove.language/") {
                found.insert(PluginCategory::Languages);
            } else if point.starts_with("cove.ai.") {
                found.insert(PluginCategory::Ai);
            } else if point.starts_with("cove.ui.") || point.starts_with("cove.command/") {
                found.insert(PluginCategory::Ui);
            } else if point.starts_with("cove.vcs/") {
                found.insert(PluginCategory::VersionControl);
            } else if point.starts_with("cove.tasks/") {
                found.insert(PluginCategory::Tasks);
            } else {
                found.insert(PluginCategory::Other);
            }
        }
        if found.is_empty() {
            found.insert(if has_capabilities {
                PluginCategory::Ai
            } else {
                PluginCategory::Other
            });
        }
        PluginCategory::ALL
            .into_iter()
            .filter(|category| found.contains(category))
            .collect()
    }
}
