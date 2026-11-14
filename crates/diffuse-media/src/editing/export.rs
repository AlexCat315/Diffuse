//! Desktop render worker.
//!
//! FFmpeg receives argv directly; authored paths never enter shell code, so a
//! clip named `a;rm -rf /` stays one argument.
//!
//! Swift's `MediaExporter` is an actor with a single immutable property, so the
//! Rust translation is a plain struct: there is no shared mutable state to
//! serialize (MIGRATION.md §5.5).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::decoding::values::{MediaAsset, MediaError, MediaUrl};
use crate::editing::composition::MediaComposition;

/// `public actor MediaExporter`.
pub struct MediaExporter {
    executable: PathBuf,
}

impl MediaExporter {
    /// `public init(executable: URL)`.
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        MediaExporter {
            executable: executable.into(),
        }
    }

    /// `public func export(_:projectRoot:to:) throws`.
    pub fn export(
        &self,
        composition: &MediaComposition,
        project_root: &MediaUrl,
        output: &MediaUrl,
    ) -> Result<(), MediaError> {
        composition.validate()?;
        if !output.is_file_url() || !output.path_extension().eq_ignore_ascii_case("mp4") {
            return Err(MediaError::Invalid(
                "Export destination must be a local .mp4 file".to_string(),
            ));
        }
        // `FileManager.fileExists(atPath:)` is true for anything at the path.
        if Path::new(output.path()).exists() {
            return Err(MediaError::Export(
                "Export destination already exists".to_string(),
            ));
        }
        let arguments = ExportPlan::arguments(composition, project_root)?;
        let temporary = output
            .deleting_last_path_component()
            .appending_path_component(&format!(".cove-{}.mp4", uuid_string()));
        let log = std::env::temp_dir().join(format!("cove-media-{}.log", uuid_string()));

        // Swift's `defer { try? ...removeItem(at: log); try? ...removeItem(at:
        // temporary) }` runs on every exit path, including a failed rename. The
        // optional removes are no-ops once the rename has moved the file away.
        let _cleanup = RemoveOnDrop {
            temporary: temporary.path().to_string(),
            log: log.clone(),
        };

        // `FileManager.createFile(atPath:contents:nil)` then a handle for stderr.
        let log_handle =
            std::fs::File::create(&log).map_err(|error| MediaError::Export(error.to_string()))?;

        let status = Command::new(&self.executable)
            .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-n"])
            .args(&arguments)
            .arg(temporary.path())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log_handle))
            .status()
            .map_err(|error| MediaError::Export(error.to_string()))?;
        if status.code() != Some(0) {
            return Err(failure_message(&log));
        }

        std::fs::rename(temporary.path(), output.path())
            .map_err(|error| MediaError::Export(error.to_string()))?;
        Ok(())
    }
}

/// The `defer` body of `MediaExporter.export`: both paths are removed on drop,
/// and a missing file is ignored, matching `try?`.
struct RemoveOnDrop {
    temporary: String,
    log: PathBuf,
}

impl Drop for RemoveOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.temporary);
        let _ = std::fs::remove_file(&self.log);
    }
}

/// Swift reads the log only on failure, keeps its last 8192 bytes, and falls back
/// to the literal `"FFmpeg failed"` when the log is unreadable.
fn failure_message(log: &Path) -> MediaError {
    match std::fs::read(log) {
        Ok(bytes) => {
            let tail = if bytes.len() > 8192 {
                &bytes[bytes.len() - 8192..]
            } else {
                &bytes[..]
            };
            MediaError::Export(String::from_utf8_lossy(tail).into_owned())
        }
        Err(_) => MediaError::Export("FFmpeg failed".to_string()),
    }
}

/// A random v4 UUID formatted exactly as Swift's `UUID().uuidString`: 36
/// characters, groups of 8-4-4-4-12. `diffuse-kernel::codable::new_uuid` is the
/// canonical implementation; keep this one byte-identical to it.
fn uuid_string() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let time_low = (mixed & 0xFFFF_FFFF) as u32;
    let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
    let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
    let clock = ((counter & 0x3FFF) as u16) | 0x8000;
    let node: u64 = (mixed >> 8) & 0x0000_FFFF_FFFF_FFFF;
    format!("{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node:012X}")
}

/// `enum ExportPlan` — the FFmpeg argument vector.
pub struct ExportPlan;

impl ExportPlan {
    /// `static func arguments(_:root:) throws -> [String]`.
    pub fn arguments(
        composition: &MediaComposition,
        root: &MediaUrl,
    ) -> Result<Vec<String>, MediaError> {
        // `root.resolvingSymlinksInPath().standardizedFileURL`
        let root = root.resolving_symlinks_in_path().standardized_file_url();
        let mut inputs: Vec<String> = Vec::new();
        let mut filters: Vec<String> = Vec::new();
        let mut outputs: Vec<String> = Vec::new();
        let video = &composition.video;
        for (index, clip) in composition.clips.iter().enumerate() {
            // `root.appendingPathComponent(clip.source)`, symlinks resolved, then
            // the containment check against the root prefix.
            let url = root
                .appending_path_component(&clip.source)
                .resolving_symlinks_in_path()
                .standardized_file_url();
            let source_path = Path::new(url.path());
            let root_path = Path::new(root.path());
            if source_path == root_path || !source_path.starts_with(root_path) {
                return Err(MediaError::Invalid(
                    "Media source escapes project root".to_string(),
                ));
            }
            let asset = MediaAsset::inspect(&url)?;
            let covers_range =
                asset.video.is_some() && asset.duration >= clip.start + clip.duration - 0.05;
            if !covers_range {
                return Err(MediaError::Invalid(format!(
                    "Clip range exceeds video source: {}",
                    clip.source
                )));
            }
            inputs.push("-i".to_string());
            inputs.push(url.path().to_string());
            filters.push(format!(
                "[{index}:v]trim=start={}:duration={},setpts=PTS-STARTPTS,scale={}:{}:force_original_aspect_ratio=decrease,pad={}:{}:(ow-iw)/2:(oh-ih)/2,fps={},format=yuv420p[v{index}]",
                clip.start, clip.duration, video.width, video.height, video.width, video.height,
                video.frames_per_second
            ));
            if asset.has_audio {
                filters.push(format!(
                    "[{index}:a]atrim=start={}:duration={},asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo[a{index}]",
                    clip.start, clip.duration
                ));
            } else {
                filters.push(format!(
                    "anullsrc=r=48000:cl=stereo,atrim=duration={}[a{index}]",
                    clip.duration
                ));
            }
            outputs.push(format!("[v{index}][a{index}]"));
        }
        filters.push(format!(
            "{}concat=n={}:v=1:a=1[v][a]",
            outputs.concat(),
            composition.clips.len()
        ));
        let mut arguments = inputs;
        arguments.extend([
            "-filter_complex".to_string(),
            filters.join(";"),
            "-map".to_string(),
            "[v]".to_string(),
            "-map".to_string(),
            "[a]".to_string(),
            "-c:v".to_string(),
            "mpeg4".to_string(),
            "-q:v".to_string(),
            "3".to_string(),
            "-c:a".to_string(),
            "aac".to_string(),
            "-b:a".to_string(),
            "192k".to_string(),
            "-movflags".to_string(),
            "+faststart".to_string(),
        ]);
        Ok(arguments)
    }
}
