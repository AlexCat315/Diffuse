//! Translation of
//! Editor/Sources/EditorUI/Panels/AssetBrowser/AssetImportFileCopier.swift.
//!
//! Copies imported assets through a sibling staging file so re-importing never
//! deletes the last known-good project file before the replacement is ready.

use std::path::Path;

use cove_system::replacement::FileReplacement;

pub struct AssetImportFileCopier;

impl AssetImportFileCopier {
    pub fn copy_replacing(source: &Path, destination: &Path) -> std::io::Result<()> {
        let parent = destination
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        std::fs::create_dir_all(parent)?;

        let file_name = destination
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let staging = parent.join(format!(
            ".{file_name}.import-{}",
            diffuse_kernel::codable::new_uuid()
        ));
        let result = (|| {
            std::fs::copy(source, &staging)?;
            if destination.exists() {
                FileReplacement::replace(destination, &staging)
            } else {
                std::fs::rename(&staging, destination)
            }
        })();
        // Swift's `defer { try? fileManager.removeItem(at: staging) }`.
        let _ = std::fs::remove_file(&staging);
        result
    }
}
