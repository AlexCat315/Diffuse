//! Translation of Editor/Sources/EditorUI/Projects/ProjectList.swift.
//!
//! The projects the window keeps open across launches, in sidebar order, and
//! the one in front.

use cove_ui_compose::app_storage::{AppStorageDefaults, AppStorageStore, AppStorageValue};
use diffuse_editor_core::projects::standardized_path;

const OPEN_KEY: &str = "CoveOpenProjects";
const ACTIVE_KEY: &str = "CoveActiveProject";

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EditorProjectList {
    pub paths: Vec<String>,
    pub active: Option<String>,
}

impl EditorProjectList {
    /// Swift's `URL(fileURLWithPath:isDirectory:).standardizedFileURL
    /// .resolvingSymlinksInPath().path`.
    pub fn canonical_path(path: &str) -> String {
        standardized_path(std::path::Path::new(path))
            .to_string_lossy()
            .into_owned()
    }

    pub fn load() -> Self {
        Self::load_from(&*AppStorageDefaults::store())
    }

    /// Reads the saved list from `store`. Blank entries are dropped, every path
    /// is canonicalized, and the first spelling of a project wins.
    pub fn load_from(store: &dyn AppStorageStore) -> Self {
        let mut seen = std::collections::HashSet::new();
        let paths: Vec<String> = open_paths(store)
            .into_iter()
            .filter(|path| !path.trim().is_empty())
            .map(|path| Self::canonical_path(&path))
            .filter(|path| seen.insert(path.clone()))
            .collect();
        let active = active_path(store)
            .map(|path| Self::canonical_path(&path))
            .filter(|path| paths.contains(path));
        EditorProjectList { paths, active }
    }

    pub fn save(&self) {
        self.save_to(&*AppStorageDefaults::store());
    }

    pub fn save_to(&self, store: &dyn AppStorageStore) {
        let encoded = serde_json::to_string(&self.paths).unwrap_or_else(|_| "[]".to_string());
        store.set(OPEN_KEY, Some(AppStorageValue::String(encoded)));
        match &self.active {
            Some(active) => store.set(ACTIVE_KEY, Some(AppStorageValue::String(active.clone()))),
            None => store.set(ACTIVE_KEY, None),
        }
    }
}

/// Swift's `defaults.stringArray(forKey:)`. The store holds scalars, so the
/// list is persisted as one JSON array string under the same key.
fn open_paths(store: &dyn AppStorageStore) -> Vec<String> {
    match store.value(OPEN_KEY) {
        Some(AppStorageValue::String(encoded)) => {
            serde_json::from_str::<Vec<String>>(&encoded).unwrap_or_default()
        }
        _ => Vec::new(),
    }
}

fn active_path(store: &dyn AppStorageStore) -> Option<String> {
    match store.value(ACTIVE_KEY) {
        Some(AppStorageValue::String(path)) => Some(path),
        _ => None,
    }
}
