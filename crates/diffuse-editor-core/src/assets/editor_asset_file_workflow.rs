//! `Editor/Sources/EditorCore/Assets/EditorAssetFileWorkflow.swift`.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use cove_system::paths::PathIdentity;
use diffuse_assets::swift_json::{SwiftJsonError, to_sorted_pretty};
use serde_json::Value;

use super::asset_import_resolver::AssetImportResolver;

pub enum EditorAssetFileWorkflow {}

#[derive(Debug, thiserror::Error)]
pub enum AssetFileWorkflowError {
    #[error("{0}")]
    Failure(String),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Json(#[from] SwiftJsonError),
    #[error("{cause}. Rollback could not restore: {}", .paths.join(", "))]
    Rollback {
        #[source]
        cause: Box<Self>,
        paths: Vec<String>,
    },
}

struct Rewrite {
    path: PathBuf,
    original: Vec<u8>,
    replacement: Vec<u8>,
}

impl EditorAssetFileWorkflow {
    pub fn reference_files(source: &Path, root: &Path) -> Vec<PathBuf> {
        text_files(root)
            .into_iter()
            .filter(|path| {
                fs::read(path)
                    .ok()
                    .and_then(|data| {
                        rewrite(&data, path, source, source, root, true)
                            .ok()
                            .flatten()
                    })
                    .is_some()
            })
            .collect()
    }

    /// Restores a file and its relative dependencies. A failed validation
    /// removes only the files created by this operation.
    pub fn restore_missing(
        replacement: &Path,
        target: &Path,
        root: &Path,
        validate: impl FnOnce() -> Result<(), AssetFileWorkflowError>,
    ) -> Result<(), AssetFileWorkflowError> {
        let replacement = std::path::absolute(replacement)?;
        let target = project_file(target, root)?;
        if exists(&target)?
            || !replacement.is_file()
            || extension(&replacement) != extension(&target)
        {
            return Err(failure(
                "Select a replacement of the same format for a missing project file.",
            ));
        }

        let dependencies = dependency_copies(&replacement, &target, root);
        validate_dependencies(
            &dependencies,
            root,
            "The replacement has missing dependencies or paths outside the project.",
        )?;
        let mut copied = Vec::new();
        let result = (|| {
            copy_new(&replacement, &target, &mut copied)?;
            copy_dependencies(&dependencies, &mut copied)?;
            validate()
        })();
        result.map_err(|cause| {
            let paths = remove_copies(&copied);
            rollback_error(cause, paths)
        })
    }

    /// Moves an asset, copying its dependencies and updating project references.
    pub fn relocate(
        source: &Path,
        destination: &Path,
        root: &Path,
    ) -> Result<Vec<PathBuf>, AssetFileWorkflowError> {
        let source_file = project_file(source, root)?;
        let destination_file = project_file(destination, root)?;
        if PathIdentity::same_location(&source_file, &destination_file) {
            return Ok(Vec::new());
        }
        if extension(&source_file) != extension(&destination_file) {
            return Err(failure(
                "Keep the asset's file extension when renaming or moving it.",
            ));
        }
        if !source_file.is_file() || exists(&destination_file)? {
            return Err(failure(
                "The source is missing or the destination already exists.",
            ));
        }

        let dependencies = dependency_copies(&source_file, &destination_file, root);
        validate_dependencies(
            &dependencies,
            root,
            "Repair missing model dependencies before moving this asset.",
        )?;

        let mut rewrites = Vec::new();
        for path in text_files(root) {
            let original = fs::read(&path)?;
            if let Some(replacement) = rewrite(&original, &path, source, destination, root, false)?
                && replacement != original
            {
                rewrites.push(Rewrite {
                    path,
                    original,
                    replacement,
                });
            }
        }

        let mut copied = Vec::new();
        let mut written = Vec::new();
        let source_rewrite = rewrites
            .iter()
            .position(|item| PathIdentity::same_location(&item.path, &source_file));
        let mut moved = false;
        let result = (|| {
            copy_dependencies(&dependencies, &mut copied)?;
            move_new(&source_file, &destination_file)?;
            moved = true;
            for (index, item) in rewrites.iter().enumerate() {
                let target = if Some(index) == source_rewrite {
                    &destination_file
                } else {
                    &item.path
                };
                AtomicFile::write(&item.replacement, target, Access::Inherit)?;
                written.push((target, item));
            }
            Ok(())
        })();
        if let Err(cause) = result {
            let mut paths = Vec::new();
            for (target, item) in written.into_iter().rev() {
                if AtomicFile::write(&item.original, target, Access::Inherit).is_err() {
                    paths.push(target.display().to_string());
                }
            }
            if moved && move_new(&destination_file, &source_file).is_err() {
                paths.push(source_file.display().to_string());
            }
            paths.extend(remove_copies(&copied));
            return Err(rollback_error(cause, paths));
        }
        Ok(rewrites.into_iter().map(|item| item.path).collect())
    }

    pub fn relative_path(path: &Path, directory: &Path) -> String {
        PathIdentity::relative_path(path, directory)
    }

    pub fn project_relative_path(path: &Path, root: &Path) -> Option<String> {
        let (path, root) = (absolute(path), absolute(root));
        PathIdentity::contains(&path, &root, true).then(|| Self::relative_path(&path, &root))
    }
}

fn project_file(path: &Path, root: &Path) -> Result<PathBuf, AssetFileWorkflowError> {
    let path = std::path::absolute(path)?;
    let root = std::path::absolute(root)?;
    let canonical_parent = PathIdentity::canonical_url(parent(&path));
    if let Some(name) = path.file_name() {
        let file = canonical_parent.join(name);
        if PathIdentity::contains(&file, &root, false) {
            return Ok(file);
        }
    }
    Err(failure(
        "The source and destination must stay inside the project.",
    ))
}

fn dependency_copies(source: &Path, destination: &Path, root: &Path) -> Vec<(PathBuf, PathBuf)> {
    AssetImportResolver::resolve(source, Some(&absolute(root)))
        .into_iter()
        .skip(1)
        .filter_map(|dependency| {
            let target = parent(destination).join(dependency.relative_path);
            // Normalize parent-relative references before checking and writing.
            let target = absolute(&target);
            let target = PathIdentity::canonical_url(parent(&target)).join(target.file_name()?);
            (!PathIdentity::same_location(&dependency.source, &target))
                .then_some((dependency.source, target))
        })
        .collect()
}

fn validate_dependencies(
    dependencies: &[(PathBuf, PathBuf)],
    root: &Path,
    missing: &str,
) -> Result<(), AssetFileWorkflowError> {
    let root = absolute(root);
    for (source, target) in dependencies {
        if !PathIdentity::contains(target, &root, false) || !source.is_file() {
            return Err(failure(missing));
        }
        check_dependency_conflict(source, target)?;
    }
    Ok(())
}

fn check_dependency_conflict(source: &Path, target: &Path) -> Result<bool, AssetFileWorkflowError> {
    if !exists(target)? {
        return Ok(false);
    }
    if fs::read(source)? != fs::read(target)? {
        return Err(failure(format!(
            "A different dependency already exists at {}.",
            target.file_name().unwrap_or_default().to_string_lossy()
        )));
    }
    Ok(true)
}

fn copy_dependencies(
    dependencies: &[(PathBuf, PathBuf)],
    copied: &mut Vec<PathBuf>,
) -> Result<(), AssetFileWorkflowError> {
    for (source, target) in dependencies {
        if !check_dependency_conflict(source, target)? {
            copy_new(source, target, copied)?;
        }
    }
    Ok(())
}

fn copy_new(source: &Path, target: &Path, copied: &mut Vec<PathBuf>) -> io::Result<()> {
    let mut input = File::open(source)?;
    fs::create_dir_all(parent(target))?;
    let mut output = create_new(target)?;
    copied.push(target.to_owned());
    copy_contents(&mut input, &mut output)
}

fn move_new(source: &Path, target: &Path) -> Result<(), AssetFileWorkflowError> {
    fs::create_dir_all(parent(target))?;
    // Reserve the name before calling rename, which may replace its target.
    drop(create_new(target)?);
    let result = match fs::rename(source, target) {
        Err(error) if error.kind() == io::ErrorKind::CrossesDevices => (|| {
            let mut input = File::open(source)?;
            let mut output = OpenOptions::new().write(true).open(target)?;
            copy_contents(&mut input, &mut output)?;
            drop(input);
            drop(output);
            fs::remove_file(source)
        })(),
        other => other,
    };
    result.map_err(|cause| rollback_error(cause.into(), remove_copies(&[target.to_owned()])))
}

fn create_new(path: &Path) -> io::Result<File> {
    OpenOptions::new().write(true).create_new(true).open(path)
}

fn copy_contents(input: &mut File, output: &mut File) -> io::Result<()> {
    let metadata = input.metadata()?;
    io::copy(input, output)?;
    let mut times = fs::FileTimes::new();
    if let Ok(modified) = metadata.modified() {
        times = times.set_modified(modified);
    }
    if let Ok(accessed) = metadata.accessed() {
        times = times.set_accessed(accessed);
    }
    output.set_times(times)?;
    output.set_permissions(metadata.permissions())
}

fn remove_copies(paths: &[PathBuf]) -> Vec<String> {
    paths
        .iter()
        .rev()
        .filter(|path| fs::remove_file(path).is_err())
        .map(|path| path.display().to_string())
        .collect()
}

fn rollback_error(cause: AssetFileWorkflowError, paths: Vec<String>) -> AssetFileWorkflowError {
    if paths.is_empty() {
        cause
    } else {
        AssetFileWorkflowError::Rollback {
            cause: Box::new(cause),
            paths,
        }
    }
}

fn failure(message: impl Into<String>) -> AssetFileWorkflowError {
    AssetFileWorkflowError::Failure(message.into())
}

fn exists(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn parent(path: &Path) -> &Path {
    path.parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
}

fn absolute(path: &Path) -> PathBuf {
    std::path::absolute(path).unwrap_or_else(|_| path.to_owned())
}

fn extension(path: &Path) -> String {
    path.extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_ascii_lowercase()
}

fn text_files(root: &Path) -> Vec<PathBuf> {
    const EXCLUDED: &[&str] = &[
        ".git",
        ".build",
        "build",
        "target",
        "vendor",
        "node_modules",
        "export",
        "compiled",
        "script-cache",
    ];
    let root = PathIdentity::canonical_url(&absolute(root));
    let mut directories = vec![root.clone()];
    let mut result = Vec::new();
    while let Some(directory) = directories.pop() {
        let Ok(entries) = fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let path = entry.path();
            if kind.is_dir() && !EXCLUDED.contains(&entry.file_name().to_string_lossy().as_ref()) {
                directories.push(path);
            } else if kind.is_file()
                && matches!(
                    extension(&path).as_str(),
                    "json" | "gltf" | "obj" | "mtl" | "swift" | "rs" | "covescene"
                )
                && entry
                    .metadata()
                    .is_ok_and(|metadata| metadata.len() < 8_000_000)
                && PathIdentity::contains(&path, &root, false)
            {
                result.push(path);
            }
        }
    }
    result.sort();
    result
}

fn rewrite(
    data: &[u8],
    owner: &Path,
    source: &Path,
    destination: &Path,
    root: &Path,
    detect_only: bool,
) -> Result<Option<Vec<u8>>, SwiftJsonError> {
    let original_source = source.to_string_lossy();
    let original_destination = destination.to_string_lossy();
    let (source, destination, root) = (absolute(source), absolute(destination), absolute(root));
    let directory = parent(owner);
    let old_id = PathIdentity::relative_path(&source, &root);
    let new_id = PathIdentity::relative_path(&destination, &root);
    let old_relative = PathIdentity::relative_path(&source, directory);
    let new_relative = PathIdentity::relative_path(&destination, directory);
    let old_absolute = source.to_string_lossy();
    let kind = extension(owner);

    if matches!(kind.as_str(), "json" | "gltf" | "covescene")
        && let Ok(mut json) = serde_json::from_slice(data)
    {
        let replace = |key: &str, text: &str| {
            if key == "uri" {
                let decoded = decode_uri(text)?;
                return (!decoded.contains("://")
                    && !decoded.starts_with("data:")
                    && PathIdentity::same_location(&directory.join(decoded), &source))
                .then(|| encode_uri(&new_relative));
            }
            if text == original_source
                || (Path::new(text).is_absolute()
                    && PathIdentity::same_location(Path::new(text), &source))
            {
                return Some(original_destination.to_string());
            }
            if text == old_id {
                return Some(new_id.clone());
            }
            if text == old_relative || decode_uri(text).as_deref() == Some(old_relative.as_str()) {
                return Some(if text.contains('%') {
                    encode_uri(&new_relative)
                } else {
                    new_relative.clone()
                });
            }
            None
        };
        if !rewrite_json(&mut json, "", &replace) {
            return Ok(None);
        }
        return if detect_only {
            Ok(Some(data.to_vec()))
        } else {
            to_sorted_pretty(&json).map(|text| Some(text.into_bytes()))
        };
    }

    let Ok(text) = std::str::from_utf8(data) else {
        return Ok(None);
    };
    let mut matched = false;
    let next = match kind.as_str() {
        "swift" | "rs" => {
            let mut text = text.to_owned();
            for (old, new) in [
                (&*old_id, &*new_id),
                (&*original_source, &*original_destination),
                (&*old_absolute, &*original_destination),
            ] {
                let old = string_literal(old);
                if text.contains(&old) {
                    matched = true;
                    text = text.replace(&old, &string_literal(new));
                }
            }
            text
        }
        "obj" | "mtl" => {
            let suffix = format!(" {old_relative}");
            let mut rewritten = String::with_capacity(text.len());
            for line in text.split_inclusive('\n') {
                let body = line.trim_end_matches(['\r', '\n']);
                let directive = body.trim_start();
                if (directive.starts_with("mtllib ")
                    || directive.starts_with("map_")
                    || directive.starts_with("bump "))
                    && let Some(prefix) = body.strip_suffix(&suffix)
                {
                    matched = true;
                    rewritten.push_str(prefix);
                    rewritten.push(' ');
                    rewritten.push_str(&new_relative);
                    rewritten.push_str(&line[body.len()..]);
                } else {
                    rewritten.push_str(line);
                }
            }
            rewritten
        }
        _ => return Ok(None),
    };
    Ok(matched.then(|| {
        if detect_only {
            data.to_vec()
        } else {
            next.into_bytes()
        }
    }))
}

fn rewrite_json(
    value: &mut Value,
    key: &str,
    replace: &impl Fn(&str, &str) -> Option<String>,
) -> bool {
    let mut matched = false;
    match value {
        Value::Array(items) => {
            for item in items {
                matched |= rewrite_json(item, key, replace);
            }
        }
        Value::Object(fields) => {
            for (key, item) in fields {
                matched |= rewrite_json(item, key, replace);
            }
        }
        Value::String(text) => {
            if let Some(replacement) = replace(key, text) {
                *text = replacement;
                matched = true;
            }
        }
        _ => {}
    }
    matched
}

fn decode_uri(text: &str) -> Option<String> {
    if !text.contains('%') {
        return Some(text.to_owned());
    }
    let mut result = Vec::with_capacity(text.len());
    let mut input = text.bytes();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let high = char::from(input.next()?).to_digit(16)?;
            let low = char::from(input.next()?).to_digit(16)?;
            result.push((high * 16 + low) as u8);
        } else {
            result.push(byte);
        }
    }
    String::from_utf8(result).ok()
}

fn encode_uri(text: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut result = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"!$&'()*+,-./:=@_~".contains(&byte) {
            result.push(char::from(byte));
        } else {
            result.push('%');
            result.push(char::from(HEX[(byte >> 4) as usize]));
            result.push(char::from(HEX[(byte & 0xf) as usize]));
        }
    }
    result
}

fn string_literal(text: &str) -> String {
    format!(
        "\"{}\"",
        text.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
            .replace('\t', "\\t")
    )
}
