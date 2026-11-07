//! `StageOperation.swift` — `--platform`, `--vendor`, `--check`: the former
//! `stage.py` command line.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::bundle::{
    ArtifactBundle, ArtifactBundleArtifact, ArtifactBundleVariant, Provenance,
    StaticLibraryMetadata,
};
use super::entry::{LIBRARIES, MediaStaging, SOURCE_SHA256, USAGE, VERSION};
use super::source_download::SourceDownload;
use super::targets::Targets;
use crate::support::terminal::{Terminal, ToolError};
use crate::support::{archive, files, repository, sha256, shell};

pub enum StageOperation {}

impl StageOperation {
    pub fn run(
        arguments: &[String],
        environment: &BTreeMap<String, String>,
    ) -> Result<(), ToolError> {
        let mut platform: Option<String> = None;
        let mut vendor: Option<String> = None;
        let mut check = false;
        let mut index = 0;
        while index < arguments.len() {
            let token = arguments[index].clone();
            index += 1;
            match token.as_str() {
                "-h" | "--help" => {
                    Terminal::info(USAGE);
                    return Ok(());
                }
                "--check" => check = true,
                "--platform" | "--vendor" => {
                    if index >= arguments.len() {
                        return Err(ToolError::message(format!(
                            "argument {token}: expected one argument"
                        )));
                    }
                    if token == "--platform" {
                        platform = Some(arguments[index].clone());
                    } else {
                        vendor = Some(arguments[index].clone());
                    }
                    index += 1;
                }
                _ => {
                    if let Some(value) = inline_value("--platform", &token) {
                        platform = Some(value);
                    } else if let Some(value) = inline_value("--vendor", &token) {
                        vendor = Some(value);
                    } else {
                        return Err(ToolError::message(format!(
                            "unrecognized arguments: {token}"
                        )));
                    }
                }
            }
        }
        let vendor_root = match vendor {
            Some(path) => absolute_path(&path),
            None => MediaStaging::default_vendor(),
        };
        // Foundation's `resolvingSymlinksInPath()` resolves existing prefixes
        // and lexically standardizes the rest; `canonicalize` needs a live path.
        let vendor_root = std::fs::canonicalize(&vendor_root)
            .unwrap_or_else(|_| repository::standardized(&vendor_root));
        let name = platform.unwrap_or_else(Targets::host);
        Self::stage(&name, &vendor_root, check, environment)
    }

    /// Whether the staged variant matches the pinned version, the pinned
    /// source digest and every file digest recorded in its provenance stamp.
    pub fn is_ready(platform: &str, vendor: &Path) -> bool {
        let ready = || -> Result<bool, ToolError> {
            let variant = vendor.join("FFmpeg.artifactbundle").join(platform);
            let data = files::read(&variant.join("provenance.json")).map_err(io_error)?;
            let provenance: Provenance = serde_json::from_slice(&data).map_err(json_error)?;
            if provenance.version != VERSION
                || provenance.source_sha256 != SOURCE_SHA256
                || provenance.files.is_empty()
            {
                return Ok(false);
            }
            for (path, digest) in &provenance.files {
                match sha256::hex_file(&variant.join(path)) {
                    Ok(actual) if actual == *digest => {}
                    _ => return Ok(false),
                }
            }
            Ok(true)
        };
        ready().unwrap_or(false)
    }

    pub fn stage(
        name: &str,
        vendor: &Path,
        check: bool,
        environment: &BTreeMap<String, String>,
    ) -> Result<(), ToolError> {
        if !Targets::SUPPORTED.contains(&name) {
            return Err(ToolError::message("Unsupported FFmpeg target"));
        }
        let bundle = vendor.join("FFmpeg.artifactbundle");
        let variant = bundle.join(name);
        let stamp = variant.join("provenance.json");

        if check {
            if !Self::is_ready(name, vendor) {
                return Err(ToolError::message(format!("FFmpeg {name} is not staged")));
            }
            return Ok(());
        }

        let cache = repository::path("Engine/Media/build/cache");
        files::directory(&cache).map_err(io_error)?;
        let source_archive = cache.join(format!("ffmpeg-{VERSION}.tar.xz"));
        SourceDownload::fetch_many(
            &MediaStaging::source_urls(),
            &source_archive,
            SOURCE_SHA256,
            environment,
        )?;

        let source = cache.join(format!("ffmpeg-{VERSION}"));
        // A partial extraction can leave `source` present but missing key
        // files, which would otherwise be reused on a later run.
        let source_ready = source.join("configure").exists() && source.join("Makefile").exists();
        if !source_ready {
            if source.exists() {
                files::remove(&source).map_err(io_error)?;
            }
            archive::extract(&source_archive, &cache, 0, environment)?;
        }

        let build = repository::path(&format!("Engine/Media/build/{name}"));
        files::directory(&build).map_err(io_error)?;

        // FFmpeg's out-of-tree wrapper Makefile includes the source Makefile
        // by absolute path; MSVC/MSYS2 make cannot resolve that path. Windows
        // therefore builds in-tree; macOS/Linux keep the out-of-tree layout.
        let build_dir = if name.starts_with("windows-") {
            source.clone()
        } else {
            build.clone()
        };
        let prefix = build_dir.join("install");
        let mut options = Self::configure_options(&prefix);
        options.extend(Targets::options(name, environment)?);
        // `SDKROOT` is what the clang driver itself reads as its default
        // sysroot, so exporting it covers configure's host link; the target
        // compile already carries an explicit `--sysroot`.
        let mut child_environment = environment.clone();
        if name.starts_with("macos-") || name.starts_with("ios-") {
            child_environment.insert("SDKROOT".to_string(), Targets::host_sysroot(environment)?);
        }
        let mut configure = vec![
            "sh".to_string(),
            source.join("configure").display().to_string(),
        ];
        configure.append(&mut options);
        shell::inherit(&configure, Some(&build_dir), &child_environment, None)?;
        shell::inherit(
            &["make".into(), "-j4".into()],
            Some(&build_dir),
            &child_environment,
            None,
        )?;
        shell::inherit(
            &["make".into(), "install".into()],
            Some(&build_dir),
            &child_environment,
            None,
        )?;

        files::directory(&variant).map_err(io_error)?;
        Self::merge(&prefix.join("include"), &variant.join("include"))?;
        Self::merge(&prefix.join("lib"), &variant.join("lib"))?;
        if prefix.join("bin").exists() {
            Self::merge(&prefix.join("bin"), &variant.join("bin"))?;
        }
        for license in ["COPYING.LGPLv2.1", "COPYING.LGPLv3", "LICENSE.md"] {
            files::copy(&source.join(license), &bundle.join(license)).map_err(io_error)?;
        }

        let windows = name.starts_with("windows-");
        let filename = if windows { "FFmpeg.lib" } else { "libFFmpeg.a" };
        let libraries: Vec<PathBuf> = LIBRARIES
            .iter()
            .map(|library| {
                variant.join("lib").join(if windows {
                    format!("{library}.lib")
                } else {
                    format!("lib{library}.a")
                })
            })
            .collect();
        let combined = variant.join("lib").join(filename);
        let library_paths: Vec<String> = libraries
            .iter()
            .map(|path| path.display().to_string())
            .collect();
        if windows {
            let mut command = vec!["lib".to_string(), format!("/OUT:{}", combined.display())];
            command.extend(library_paths);
            shell::inherit(&command, None, environment, None)?;
        } else if name.starts_with("ios-") || name.starts_with("macos-") {
            let mut command = vec![
                "xcrun".into(),
                "libtool".into(),
                "-static".into(),
                "-o".into(),
                combined.display().to_string(),
            ];
            command.extend(library_paths);
            shell::inherit(&command, None, environment, None)?;
        } else {
            let android = name.starts_with("android-");
            let ar = if android {
                configure
                    .iter()
                    .find(|option| option.starts_with("--ar="))
                    .map(|option| option.trim_start_matches("--ar=").to_string())
                    .unwrap_or_else(|| "ar".to_string())
            } else {
                "ar".to_string()
            };
            let script = format!(
                "CREATE {}\n{}SAVE\nEND\n",
                combined.display(),
                libraries
                    .iter()
                    .map(|path| format!("ADDLIB {}\n", path.display()))
                    .collect::<String>()
            );
            shell::inherit(&[ar, "-M".into()], None, environment, Some(&script))?;
        }

        let manifest = bundle.join("info.json");
        let mut artifacts: BTreeMap<String, ArtifactBundleArtifact> = BTreeMap::new();
        if manifest.exists() {
            // Only the FFmpeg entry survives: other artifacts in the bundle
            // are not this tool's to rewrite.
            let data = files::read(&manifest).map_err(io_error)?;
            let parsed: ArtifactBundle = serde_json::from_slice(&data).map_err(json_error)?;
            artifacts = parsed
                .artifacts
                .into_iter()
                .filter(|(key, _)| key == "FFmpeg")
                .collect();
        }
        let mut entry =
            artifacts
                .get("FFmpeg")
                .cloned()
                .unwrap_or_else(|| ArtifactBundleArtifact {
                    type_name: "staticLibrary".into(),
                    version: VERSION.into(),
                    variants: Vec::new(),
                });
        if entry.version != VERSION {
            return Err(ToolError::message(
                "Remove old FFmpeg artifacts before changing versions",
            ));
        }
        let triple = Targets::triple(name);
        entry
            .variants
            .retain(|variant| !variant.supported_triples.contains(&triple));
        entry.variants.push(ArtifactBundleVariant {
            path: format!("{name}/lib/{filename}"),
            supported_triples: vec![triple],
            static_library_metadata: StaticLibraryMetadata {
                header_paths: vec![format!("{name}/include")],
            },
        });
        artifacts.insert("FFmpeg".into(), entry);

        let mut provenance_files: BTreeMap<String, String> = BTreeMap::new();
        let standardized_stamp = repository::standardized(&stamp);
        for file in files::files_in(&variant, false).map_err(io_error)? {
            if repository::standardized(&file) == standardized_stamp {
                continue;
            }
            provenance_files.insert(
                files::relative(&file, &variant),
                sha256::hex_file(&file).map_err(io_error)?,
            );
        }
        let provenance = Provenance {
            version: VERSION.into(),
            source_sha256: SOURCE_SHA256.into(),
            license: "LGPL".into(),
            files: provenance_files,
        };
        files::json(&provenance, &stamp, true).map_err(io_error)?;

        let temporary = manifest.with_extension("tmp");
        let document = ArtifactBundle {
            schema_version: "1.0".into(),
            artifacts,
        };
        files::json(&document, &temporary, true).map_err(io_error)?;
        files::replace(&temporary, &manifest).map_err(io_error)
    }

    /// The target-independent, LGPL-only, minimal-feature configure list.
    fn configure_options(prefix: &Path) -> Vec<String> {
        [
            format!("--prefix={}", prefix.display()),
            "--disable-shared".into(),
            "--enable-static".into(),
            "--enable-pic".into(),
            "--disable-autodetect".into(),
            "--disable-gpl".into(),
            "--disable-nonfree".into(),
            "--disable-doc".into(),
            "--disable-debug".into(),
            "--disable-network".into(),
            "--disable-everything".into(),
            "--enable-avformat".into(),
            "--enable-avcodec".into(),
            "--enable-avfilter".into(),
            "--enable-swscale".into(),
            "--enable-swresample".into(),
            "--enable-ffmpeg".into(),
            "--enable-ffprobe".into(),
            "--enable-indev=lavfi".into(),
            "--enable-protocol=file,pipe".into(),
            "--enable-demuxer=mov,matroska,avi,wav,mp3,aac,ogg,flac,aiff,image2".into(),
            "--enable-decoder=h264,hevc,mpeg4,mjpeg,png,vp8,vp9,av1,aac,mp3,vorbis,opus,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be".into(),
            "--enable-parser=h264,hevc,mpeg4video,mpegaudio,aac,vorbis,opus,flac,vp9,av1".into(),
            "--enable-encoder=mpeg4,mjpeg,png,aac,flac,pcm_s16le,pcm_f32le".into(),
            "--enable-muxer=mp4,ipod,mov,matroska,wav,flac,image2,null".into(),
            "--enable-filter=buffer,abuffer,buffersink,abuffersink,trim,atrim,setpts,asetpts,concat,scale,format,aformat,aresample,anull,anullsrc,null,sine,color,volume,amix,pad,fps".into(),
        ]
        .to_vec()
    }
}

/// The value of `--name=value`, or `None` when `token` is not that option.
fn inline_value(option: &str, token: &str) -> Option<String> {
    let prefix = format!("{option}=");
    token.strip_prefix(&prefix).map(str::to_string)
}

/// Makes a possibly relative command-line path absolute against the caller's
/// working directory, matching `pathlib.Path(...).resolve()`.
fn absolute_path(path: &str) -> PathBuf {
    let candidate = Path::new(path);
    if candidate.is_absolute() {
        repository::standardized(candidate)
    } else {
        repository::standardized(
            &std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(path),
        )
    }
}

fn io_error(error: std::io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

fn json_error(error: serde_json::Error) -> ToolError {
    ToolError::message(error.to_string())
}
