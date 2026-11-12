//! Translation of `Editor/Sources/EditorCore/Assets/AssetImportResolver.swift`.
//!
//! Resolves the complete set of files an asset import must copy into the
//! project: the picked file plus every external file it references,
//! transitively, with destination paths kept relative to the asset so the
//! references stay valid.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cove_system::paths::PathIdentity;
use serde_json::Value;

pub struct AssetImportResolver;

/// One file to copy: its absolute source and its destination-relative path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedFile {
    pub source: PathBuf,
    pub relative_path: String,
}

impl AssetImportResolver {
    /// Geometry formats the asset browser can import.
    pub const SUPPORTED_MODEL_EXTENSIONS: [&'static str; 4] = ["gltf", "glb", "obj", "dmesh"];
    pub const SUPPORTED_TEXTURE_EXTENSIONS: [&'static str; 8] =
        ["png", "jpg", "jpeg", "webp", "tga", "bmp", "gif", "svg"];

    pub fn is_supported(url: &Path) -> bool {
        let extension = url
            .extension()
            .map(|extension| extension.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        Self::SUPPORTED_MODEL_EXTENSIONS.contains(&extension.as_str())
            || Self::SUPPORTED_TEXTURE_EXTENSIONS.contains(&extension.as_str())
    }

    /// Every file to copy for importing `source`. The asset itself is first;
    /// dependencies follow. Duplicate, embedded (`data:`), remote (`http(s)`)
    /// and path-escaping references are dropped. Files that don't exist on disk
    /// are still listed (the caller decides how to report them) so resolution
    /// never throws. For an existing project asset, `project_root` also allows
    /// parent-relative dependencies that remain inside that project.
    pub fn resolve(source: &Path, project_root: Option<&Path>) -> Vec<ResolvedFile> {
        let project_root = project_root
            .filter(|root| PathIdentity::contains(source, root, false))
            .map(Path::to_path_buf);
        let mut files: Vec<ResolvedFile> = Vec::new();
        let mut seen_sources: BTreeSet<String> = BTreeSet::new();

        let mut add = |source: &Path, relative_path: &str, files: &mut Vec<ResolvedFile>| -> bool {
            let allow_parents = project_root.is_some();
            let Some(relative) = normalized_relative_path(relative_path, allow_parents) else {
                return false;
            };
            if let Some(root) = project_root.as_ref()
                && !PathIdentity::contains(source, root, false)
            {
                return false;
            }
            let canonical = PathIdentity::canonical_url(source);
            if !seen_sources.insert(canonical.to_string_lossy().into_owned()) {
                return false;
            }
            files.push(ResolvedFile {
                source: canonical,
                relative_path: relative,
            });
            true
        };

        let source = PathIdentity::canonical_url(source);
        let file_name = source
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        add(&source, &file_name, &mut files);

        let extension = source
            .extension()
            .map(|extension| extension.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        match extension.as_str() {
            "gltf" => {
                for uri in gltf_referenced_uris(&source) {
                    if let Some(dependency) = referenced(&uri, &source, "", project_root.as_deref())
                    {
                        add(&dependency.source, &dependency.relative_path, &mut files);
                    }
                }
            }
            "obj" => {
                // .obj → mtllib(.mtl) → map_* textures, each resolved relative to
                // the file that references it (the .mtl may live in a subfolder).
                for mtl_name in obj_material_library_names(&source) {
                    let Some(mtl) = referenced(&mtl_name, &source, "", project_root.as_deref())
                    else {
                        continue;
                    };
                    if !add(&mtl.source, &mtl.relative_path, &mut files) {
                        continue;
                    }
                    let mtl_dir = parent_directory(&mtl.relative_path);
                    for texture_name in mtl_texture_names(&mtl.source) {
                        if let Some(texture) = referenced(
                            &texture_name,
                            &mtl.source,
                            &mtl_dir,
                            project_root.as_deref(),
                        ) {
                            add(&texture.source, &texture.relative_path, &mut files);
                        }
                    }
                }
            }
            // .glb is self-contained.
            _ => {}
        }
        files
    }

    /// Normalizes a relative path and rejects anything that would escape the
    /// destination folder (absolute paths, drive letters, `..` segments).
    pub fn sanitized_relative_path(path: &str) -> Option<String> {
        normalized_relative_path(path, false)
    }
}

fn gltf_referenced_uris(gltf: &Path) -> Vec<String> {
    let Ok(data) = std::fs::read(gltf) else {
        return Vec::new();
    };
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(&data) else {
        return Vec::new();
    };
    let mut uris = Vec::new();
    for key in ["buffers", "images"] {
        let Some(Value::Array(entries)) = root.get(key) else {
            continue;
        };
        for entry in entries {
            if let Some(Value::String(uri)) = entry.get("uri") {
                uris.push(uri.clone());
            }
        }
    }
    uris
}

/// `mtllib` may list several libraries on one line.
fn obj_material_library_names(obj: &Path) -> Vec<String> {
    directive_tails(obj, "mtllib")
}

/// Each map directive's filename is the last whitespace token; option flags
/// (`-o`, `-s`, `-bm`, …) precede it.
fn mtl_texture_names(mtl: &Path) -> Vec<String> {
    const KEYWORDS: [&str; 11] = [
        "map_kd", "map_ka", "map_ks", "map_ns", "map_d", "map_bump", "bump", "disp", "decal",
        "refl", "norm",
    ];
    let Some(text) = read_text(mtl) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    for raw_line in split_lines(&text) {
        let tokens: Vec<&str> = raw_line
            .split([' ', '\t'])
            .filter(|token| !token.is_empty())
            .collect();
        if tokens.len() >= 2
            && KEYWORDS.contains(&tokens[0].to_lowercase().as_str())
            && let Some(last) = tokens.last()
        {
            names.push((*last).to_string());
        }
    }
    names
}

/// Whitespace tokens following `keyword` on each matching line.
fn directive_tails(file: &Path, keyword: &str) -> Vec<String> {
    let Some(text) = read_text(file) else {
        return Vec::new();
    };
    let mut values = Vec::new();
    for raw_line in split_lines(&text) {
        let tokens: Vec<&str> = raw_line
            .split([' ', '\t'])
            .filter(|token| !token.is_empty())
            .collect();
        if tokens.len() >= 2 && tokens[0].to_lowercase() == keyword {
            values.extend(tokens[1..].iter().map(|token| (*token).to_string()));
        }
    }
    values
}

fn read_text(url: &Path) -> Option<String> {
    let bytes = std::fs::read(url).ok()?;
    match String::from_utf8(bytes.clone()) {
        Ok(text) => Some(text),
        // Swift falls back to ISO Latin-1: every byte is one scalar.
        Err(_) => Some(bytes.iter().map(|byte| char::from(*byte)).collect()),
    }
}

/// Swift's `split(whereSeparator: \.isNewline)`; CRLF is one separator.
fn split_lines(text: &str) -> Vec<&str> {
    fn is_newline(character: char) -> bool {
        matches!(
            character,
            '\n' | '\r' | '\u{000B}' | '\u{000C}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
        )
    }
    let mut lines = Vec::new();
    let mut start = 0_usize;
    let mut iter = text.char_indices().peekable();
    while let Some((offset, character)) = iter.next() {
        if !is_newline(character) {
            continue;
        }
        lines.push(&text[start..offset]);
        let mut next = offset + character.len_utf8();
        if character == '\r' && text[next..].starts_with('\n') {
            next += 1;
        }
        start = next;
        while let Some(&(position, _)) = iter.peek() {
            if position < start {
                iter.next();
            } else {
                break;
            }
        }
    }
    lines.push(&text[start..]);
    lines
}

/// Resolves a URI referenced by `referencing_file` (which itself lands at
/// `destination_dir` within the project) into an absolute source path and the
/// destination-relative path that keeps the reference intact.
fn referenced(
    uri: &str,
    referencing_file: &Path,
    destination_dir: &str,
    project_root: Option<&Path>,
) -> Option<ResolvedFile> {
    let trimmed = uri.trim();
    let lower = trimmed.to_lowercase();
    if trimmed.is_empty()
        || lower.starts_with("data:")
        || lower.starts_with("http://")
        || lower.starts_with("https://")
    {
        return None;
    }
    let decoded = percent_decoded(trimmed).replace('\\', "/");
    let relative_to_referencer = normalized_relative_path(&decoded, project_root.is_some())?;
    let source = referencing_file
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .join(&relative_to_referencer);
    let source = PathIdentity::canonical_url(&source);
    if let Some(root) = project_root
        && !PathIdentity::contains(&source, root, false)
    {
        return None;
    }
    let destination = if destination_dir.is_empty() {
        relative_to_referencer
    } else {
        format!("{destination_dir}/{relative_to_referencer}")
    };
    let relative_path = normalized_relative_path(&destination, project_root.is_some())?;
    Some(ResolvedFile {
        source,
        relative_path,
    })
}

fn percent_decoded(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
            if let Some(byte) = hex.and_then(|hex| u8::from_str_radix(hex, 16).ok()) {
                output.push(byte);
                index += 3;
                continue;
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(output)
        .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned())
}

fn parent_directory(relative_path: &str) -> String {
    match relative_path.rfind('/') {
        Some(slash) => relative_path[..slash].to_string(),
        None => String::new(),
    }
}

fn normalized_relative_path(path: &str, allow_parents: bool) -> Option<String> {
    let portable = path.replace('\\', "/");
    if portable.is_empty() || portable.starts_with('/') {
        return None;
    }
    let bytes = portable.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        return None;
    }
    let mut components: Vec<&str> = Vec::new();
    for component in portable.split('/') {
        if component.is_empty() || component == "." {
            continue;
        }
        if component == ".." {
            if !allow_parents {
                return None;
            }
            if let Some(last) = components.last()
                && *last != ".."
            {
                components.pop();
                continue;
            }
            components.push(component);
            continue;
        }
        components.push(component);
    }
    if components.is_empty() {
        return None;
    }
    Some(components.join("/"))
}
