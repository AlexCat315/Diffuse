//! Translation of Editor/Sources/EditorCore/Scripting/Static/ProjectStaticScripts.swift.
//!
//! Host build input for APKs. The sources are compiled into the player and are
//! not shipped as assets.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use serde::{Deserialize, Serialize};

use crate::scripting::assets::script_asset_registry::ResolvedScriptAsset;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ProjectStaticScripts {
    pub entries: Vec<StaticScriptEntry>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StaticScriptEntry {
    pub identifier: String,
    pub display_name: String,
    pub source: String,
}

impl ProjectStaticScripts {
    pub const RELATIVE_PATH: &'static str = ".cove/static-scripts.json";

    pub fn new(entries: Vec<StaticScriptEntry>) -> Self {
        ProjectStaticScripts { entries }
    }

    pub fn stage(
        assets: &[ResolvedScriptAsset],
        directory: &Path,
    ) -> Result<BTreeSet<String>, std::io::Error> {
        let sources = directory.join(".cove/static-sources");
        std::fs::create_dir_all(&sources)?;
        let mut entries = Vec::with_capacity(assets.len());
        for asset in assets {
            let relative = format!(".cove/static-sources/{}.rs", asset.id.raw_value);
            std::fs::copy(&asset.url, directory.join(&relative))?;
            entries.push(StaticScriptEntry {
                identifier: asset.id.runtime_identifier(),
                display_name: display_name(&asset.url),
                source: relative,
            });
        }
        let text =
            diffuse_assets::swift_json::to_sorted_pretty(&ProjectStaticScripts::new(entries))
                .map_err(std::io::Error::other)?;
        AtomicFile::write(
            text.as_bytes(),
            &directory.join(Self::RELATIVE_PATH),
            Access::Inherit,
        )?;
        Ok(assets
            .iter()
            .map(|asset| asset.id.runtime_identifier())
            .collect())
    }
}

fn display_name(url: &Path) -> String {
    url.file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default()
}

impl ProjectStaticScripts {
    /// Absolute path of the staged manifest inside a project directory.
    pub fn path_in(directory: &Path) -> PathBuf {
        directory.join(Self::RELATIVE_PATH)
    }
}
