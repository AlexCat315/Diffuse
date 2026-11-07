//! `Entry.swift` — builds the pinned LGPL FFmpeg libraries and desktop tools.
//!
//! Replaces `Engine/Media/Native/stage.py`. The tool is self-contained: it
//! downloads the pinned source archive, configures it per target, links the
//! combined static archive and records a provenance stamp so later runs can
//! verify readiness without network access.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::stage_operation::StageOperation;
use super::targets::Targets;
use crate::support::repository;
use crate::support::terminal::ToolError;

/// Version of the pinned FFmpeg source release.
pub const VERSION: &str = "8.1.3";
/// SHA-256 of `ffmpeg-8.1.3.tar.xz`, pinned in the former Python tool.
pub const SOURCE_SHA256: &str = "7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3";
/// Libraries linked into the combined `libFFmpeg.a` in this order.
pub const LIBRARIES: [&str; 6] = [
    "avformat",
    "avcodec",
    "avfilter",
    "swresample",
    "swscale",
    "avutil",
];

pub const USAGE: &str = "\
cove-dev media [--platform NAME] [--vendor PATH] [--check]

  --platform NAME  Target to stage; defaults to the host target.
  --vendor PATH    Artifact bundle root; defaults to Engine/Media/vendor.
  --check          Verify the staged variant and exit without building.
";

pub enum MediaStaging {}

impl MediaStaging {
    /// Mirrors carry the same upstream release bytes; every response must match
    /// `SOURCE_SHA256`.
    pub fn source_urls() -> Vec<String> {
        [
            "https://distfiles.macports.org/ffmpeg/",
            "https://mse.uk.distfiles.macports.org/ffmpeg/",
            "https://ffmpeg.org/releases/",
        ]
        .iter()
        .map(|base| format!("{base}ffmpeg-{VERSION}.tar.xz"))
        .collect()
    }

    /// `<root>/Engine/Media/vendor`, the default `--vendor` target.
    pub fn default_vendor() -> PathBuf {
        repository::path("Engine/Media/vendor")
    }

    /// `environment` defaults to this process's environment; callers that build
    /// a tailored toolchain environment (the native bootstrap) pass it down so
    /// configure, make and `xcrun` see the same compiler setup.
    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        Self::run_with_environment(arguments, &environment)
    }

    pub fn run_with_environment(
        arguments: &[String],
        environment: &BTreeMap<String, String>,
    ) -> Result<(), ToolError> {
        StageOperation::run(arguments, environment)
    }

    /// The platform key this tool stages by default for the current host.
    pub fn host() -> String {
        Targets::host()
    }

    /// Whether the staged variant for `platform` matches the pinned version
    /// and every digest recorded in its provenance stamp. Never fails; a
    /// missing or malformed stamp simply reports as not ready.
    pub fn is_ready(platform: &str, vendor: &Path) -> bool {
        StageOperation::is_ready(platform, vendor)
    }
}
