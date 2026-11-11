//! Translation of Editor/Sources/EditorCore/Assets/ProjectRuntimeResources.swift.
//!
//! Discovers project resources that are consumed directly at runtime rather than
//! imported into a render asset slot.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cove_system::paths::PathIdentity;
use diffuse_assets::project_resource_walker;
use diffuse_audio::audio_engine::AudioEngine;

pub struct ProjectRuntimeResources;

impl ProjectRuntimeResources {
    const AUDIO_EXTENSIONS: [&'static str; 7] = ["wav", "mp3", "m4a", "aiff", "aif", "caf", "ogg"];
    const EXCLUDED_DIRECTORIES: [&'static str; 7] = [
        ".git",
        ".cove",
        ".build",
        "build",
        "export",
        "node_modules",
        ".gradle",
    ];

    /// Registers the project root and every directory containing an audio clip.
    /// `AudioSource.clipName` is intentionally filename-based, so nested asset folders
    /// must be registered explicitly.
    ///
    /// Swift uses the process-wide `AudioEngine.shared`; the Rust engine is owned
    /// by its embedder, so the caller passes it in.
    pub fn configure_audio_search_paths(engine: &AudioEngine, root_path: &str) -> Vec<PathBuf> {
        let directories = Self::discover_audio_search_paths(root_path);
        engine.set_search_urls(&directories);
        directories
    }

    /// Pure discovery half of configuration, kept separate for deterministic
    /// tests without mutating the process-wide audio engine.
    pub fn discover_audio_search_paths(root_path: &str) -> Vec<PathBuf> {
        let root = PathIdentity::canonical_url(Path::new(root_path));
        let mut directories: Vec<PathBuf> = vec![root.clone()];
        let mut seen: BTreeSet<String> = BTreeSet::from([Self::path_key(&root)]);
        let files = project_resource_walker::files(&root, true, |directory| {
            let name = directory
                .file_name()
                .map(|name| name.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            Self::EXCLUDED_DIRECTORIES.contains(&name.as_str())
        });
        if let Ok(files) = files {
            for url in files {
                let extension = url
                    .extension()
                    .map(|extension| extension.to_string_lossy().to_lowercase())
                    .unwrap_or_default();
                if !Self::AUDIO_EXTENSIONS.contains(&extension.as_str()) {
                    continue;
                }
                let directory = url.parent().map(Path::to_path_buf).unwrap_or_default();
                if seen.insert(Self::path_key(&directory)) {
                    directories.push(directory);
                }
            }
        }
        directories
    }

    fn path_key(url: &Path) -> String {
        PathIdentity::comparable_components(url).join("/")
    }
}
