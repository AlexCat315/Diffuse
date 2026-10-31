//! Filesystem helpers shared by the tooling: directory creation, tree copying,
//! deterministic listings, JSON manifests and atomic replacement.

use super::terminal::ToolError;
use serde::Serialize;
use std::fs;
use std::io::{self, Write};
use std::path::{Component, Path, PathBuf};

/// Creates a directory and every missing ancestor.
pub fn directory(url: &Path) -> io::Result<()> {
    fs::create_dir_all(url)
}

/// Removes a file or directory tree when it exists.
pub fn remove(url: &Path) -> io::Result<()> {
    if !exists(url) {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(url)?;
    if metadata.is_dir() {
        fs::remove_dir_all(url)
    } else {
        fs::remove_file(url)
    }
}

/// Removes and recreates a directory.
pub fn reset(url: &Path) -> io::Result<()> {
    remove(url)?;
    directory(url)
}

fn exists(url: &Path) -> bool {
    fs::symlink_metadata(url).is_ok()
}

/// Copies one file, replacing the destination.
pub fn copy(source: &Path, destination: &Path) -> io::Result<()> {
    if let Some(parent) = destination.parent() {
        directory(parent)?;
    }
    remove(destination)?;
    fs::copy(source, destination)?;
    Ok(())
}

/// Copies a file or a whole tree, replacing the destination.
pub fn copy_tree(source: &Path, destination: &Path) -> io::Result<()> {
    if let Some(parent) = destination.parent() {
        directory(parent)?;
    }
    remove(destination)?;
    if fs::symlink_metadata(source)?.is_dir() {
        copy_directory(source, destination)
    } else {
        fs::copy(source, destination)?;
        Ok(())
    }
}

fn copy_directory(source: &Path, destination: &Path) -> io::Result<()> {
    directory(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let target = destination.join(entry.file_name());
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            copy_directory(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

pub fn read(url: &Path) -> io::Result<Vec<u8>> {
    fs::read(url)
}

pub fn text(url: &Path) -> io::Result<String> {
    fs::read_to_string(url)
}

pub fn write_text(value: &str, url: &Path) -> io::Result<()> {
    if let Some(parent) = url.parent() {
        directory(parent)?;
    }
    atomic_write(url, value.as_bytes())
}

pub fn write(url: &Path, data: &[u8]) -> io::Result<()> {
    if let Some(parent) = url.parent() {
        directory(parent)?;
    }
    atomic_write(url, data)
}

/// Encodes with sorted keys, optional pretty printing, unescaped slashes and a
/// trailing newline, matching the Swift `JSONEncoder` configuration.
pub fn json<T: Serialize>(value: &T, url: &Path, pretty: bool) -> io::Result<()> {
    let mut bytes = if pretty {
        serde_json::to_vec_pretty(value)?
    } else {
        serde_json::to_vec(value)?
    };
    bytes.push(b'\n');
    write(url, &bytes)
}

/// Writes through a sibling staging file and renames it into place.
fn atomic_write(url: &Path, data: &[u8]) -> io::Result<()> {
    let parent = url.parent().unwrap_or_else(|| Path::new("."));
    let name = url
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "cove-file".into());
    let staging = parent.join(format!(".cove-{name}-{}.tmp", std::process::id()));
    {
        let mut file = fs::File::create(&staging)?;
        file.write_all(data)?;
        file.sync_all()?;
    }
    replace(&staging, url)
}

/// Publishes a staged file at its destination, replacing existing content.
pub fn replace(staged: &Path, destination: &Path) -> io::Result<()> {
    if let Some(parent) = destination.parent() {
        directory(parent)?;
    }
    match fs::rename(staged, destination) {
        Ok(()) => Ok(()),
        Err(error) => {
            // Windows may refuse to replace an existing file; remove it first.
            if !cfg!(windows) {
                return Err(error);
            }
            remove(destination)?;
            fs::rename(staged, destination)
        }
    }
}

/// Every regular file below `root`, sorted by path. Directory entries are only
/// included when requested.
pub fn files_in(root: &Path, include_directories: bool) -> io::Result<Vec<PathBuf>> {
    let mut result = Vec::new();
    collect(root, include_directories, &mut result)?;
    result.sort();
    Ok(result)
}

fn collect(root: &Path, include_directories: bool, result: &mut Vec<PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let path = entry.path();
        if kind.is_dir() {
            if include_directories {
                result.push(path.clone());
            }
            collect(&path, include_directories, result)?;
        } else {
            result.push(path);
        }
    }
    Ok(())
}

/// Immediate children, sorted by path.
pub fn children(url: &Path) -> io::Result<Vec<PathBuf>> {
    let mut result = Vec::new();
    for entry in fs::read_dir(url)? {
        result.push(entry?.path());
    }
    result.sort();
    Ok(result)
}

/// Relative path using forward slashes, matching archive and manifest
/// conventions. Files outside the root keep their absolute path.
pub fn relative(file: &Path, root: &Path) -> String {
    relative_path(file, root)
        .components()
        .map(|component| match component {
            Component::Normal(value) => value.to_string_lossy().into_owned(),
            Component::ParentDir => "..".to_string(),
            Component::CurDir => ".".to_string(),
            Component::RootDir => String::new(),
            Component::Prefix(prefix) => prefix.as_os_str().to_string_lossy().into_owned(),
        })
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("/")
}

/// Lexical relative path, without requiring either side to exist.
pub fn relative_path(file: &Path, root: &Path) -> PathBuf {
    let file_components: Vec<Component<'_>> = file.components().collect();
    let root_components: Vec<Component<'_>> = root.components().collect();
    let mut shared = 0;
    while shared < file_components.len()
        && shared < root_components.len()
        && file_components[shared] == root_components[shared]
    {
        shared += 1;
    }
    let mut result = PathBuf::new();
    for _ in shared..root_components.len() {
        result.push("..");
    }
    for component in &file_components[shared..] {
        result.push(component.as_os_str());
    }
    result
}

/// Verifies that `candidate` stays inside `directory` after lexical resolution.
pub fn contains_path(directory: &Path, candidate: &Path) -> bool {
    let directory = normalize(directory);
    let candidate = normalize(candidate);
    candidate == directory || candidate.starts_with(&directory)
}

fn normalize(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            other => result.push(other.as_os_str()),
        }
    }
    result
}

/// Fails with a tool error when the directory cannot be read.
pub fn files_or_error(root: &Path) -> Result<Vec<PathBuf>, ToolError> {
    files_in(root, false)
        .map_err(|error| ToolError::message(format!("Cannot read {}: {error}", root.display())))
}
