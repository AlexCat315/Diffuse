//! Translation of Editor/Sources/EditorUI/Panels/Documents/Kind.swift.
//!
//! What a document path looks like to the user: a language name and a file
//! icon. Derived on demand from the file name; nothing here is stored.

use std::path::PathBuf;

use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::modifiers::interaction::AccessibilityExt;
use cove_ui_compose::primitives::media::{Image, ImageContentMode, ImageRenderingMode};
use cove_ui_compose::scene_core::Size;
use cove_ui_compose::theme::ThemeReader;
use cove_ui_compose::{AnyView, Scope, View};
use diffuse_editor_core::contributions::languages::LanguageCatalog;

use crate::resources_support::EditorAppResourceBundle;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DocumentKind {
    pub name: String,
    /// A `filetype-<key>` icon in Resources/FileIcons.
    pub icon_key: String,
    /// The contributed language's identifier, when one claims the path.
    pub language_id: Option<String>,
}

impl DocumentKind {
    pub fn new(path: &str, languages: &LanguageCatalog) -> Self {
        let file_name = path.rsplit('/').next().unwrap_or(path);
        let lower = file_name.to_lowercase();
        if let Some(special) = special_file_name(&lower).or_else(|| special_prefix(&lower)) {
            return special;
        }
        let extension = if file_name.contains('.') {
            file_name
                .rsplit('.')
                .next()
                .map(|value| value.to_lowercase())
                .unwrap_or_default()
        } else {
            String::new()
        };
        if let Some(language) = languages.descriptor_for_extension(&extension) {
            return DocumentKind {
                name: language.title,
                icon_key: language.icon_key,
                language_id: Some(language.id),
            };
        }
        if let Some(file) = file_kind(&extension) {
            return file;
        }
        if extension.is_empty() {
            DocumentKind::plain("Plain Text", "text")
        } else {
            DocumentKind::plain(&extension.to_uppercase(), "file")
        }
    }

    fn plain(name: &str, icon_key: &str) -> Self {
        DocumentKind {
            name: name.to_string(),
            icon_key: icon_key.to_string(),
            language_id: None,
        }
    }

    pub fn is_markdown(&self) -> bool {
        self.language_id.as_deref() == Some("markdown")
    }
}

fn special_file_name(lower: &str) -> Option<DocumentKind> {
    let (name, icon) = match lower {
        "makefile" => ("Makefile", "makefile"),
        "cmakelists.txt" => ("CMake", "cmake"),
        "dockerfile" => ("Dockerfile", "docker"),
        "package.json" => ("JSON", "package-json"),
        "package.resolved" => ("JSON", "lock"),
        ".gitignore" | ".gitattributes" | ".gitmodules" => ("Git", "git"),
        ".env" => ("Environment", "env"),
        ".npmrc" => ("npm", "npm"),
        "build.ninja" => ("Ninja", "ninja"),
        _ => return None,
    };
    Some(DocumentKind::plain(name, icon))
}

fn special_prefix(lower: &str) -> Option<DocumentKind> {
    if lower.starts_with("readme") {
        return Some(DocumentKind {
            name: "Markdown".to_string(),
            icon_key: "readme".to_string(),
            language_id: Some("markdown".to_string()),
        });
    }
    if lower.starts_with("license") || lower.starts_with("licence") {
        return Some(DocumentKind::plain("Plain Text", "license"));
    }
    if lower.starts_with("build.gradle") {
        return Some(DocumentKind::plain("Gradle", "gradle"));
    }
    None
}

fn file_kind(extension: &str) -> Option<DocumentKind> {
    let (name, icon) = match extension {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "tga" | "exr" | "hdr" | "ktx" | "dds"
        | "ico" => ("Image", "image"),
        "mp4" | "mov" | "mkv" | "webm" | "avi" => ("Video", "video"),
        "wav" | "mp3" | "ogg" | "flac" | "aac" | "m4a" => ("Audio", "audio"),
        "ttf" | "otf" | "woff" | "woff2" => ("Font", "font"),
        "gltf" | "glb" | "fbx" | "obj" | "dmesh" | "usd" | "usda" | "usdz" | "blend" => {
            ("3D Model", "3d")
        }
        "pdf" => ("PDF", "pdf"),
        "zip" | "tar" | "gz" | "7z" | "rar" | "xz" => ("Archive", "zip"),
        "bin" | "dat" | "o" | "a" | "dylib" | "so" | "wasm" => ("Binary", "binary"),
        "exe" | "dll" | "app" => ("Executable", "exe"),
        "db" | "sqlite" => ("Database", "database"),
        "svg" => ("SVG", "svg"),
        _ => return None,
    };
    Some(DocumentKind::plain(name, icon))
}

/// A file or folder icon in its own colours. The dark or light variant follows
/// the theme.
pub struct FileIcon {
    pub path: String,
    pub is_folder: bool,
    pub is_open: bool,
    pub size: f32,
}

impl FileIcon {
    pub fn new(path: impl Into<String>, size: f32) -> Self {
        FileIcon {
            path: path.into(),
            is_folder: false,
            is_open: false,
            size,
        }
    }

    pub fn folder(mut self, is_open: bool) -> Self {
        self.is_folder = true;
        self.is_open = is_open;
        self
    }
}

impl View for FileIcon {
    fn body(&self, _scope: &Scope) -> AnyView {
        let path = self.path.clone();
        let is_folder = self.is_folder;
        let is_open = self.is_open;
        let size = self.size;
        AnyView::new(ThemeReader::new(
            move |theme: &cove_ui_compose::theme::Theme| {
                let background = theme.colors.background;
                let is_dark =
                    0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b < 0.5;
                let base = if is_folder {
                    if is_open {
                        "folder_open".to_string()
                    } else {
                        "folder".to_string()
                    }
                } else {
                    DocumentKind::new(&path, LanguageCatalog::bundled()).icon_key
                };
                let bundle = EditorAppResourceBundle::bundle().root();
                let candidate = bundle
                    .join("FileIcons")
                    .join(format!("filetype-{base}.svg"));
                let key = if candidate.is_file() {
                    base
                } else {
                    "file".to_string()
                };
                let file_name = format!("filetype-{key}{}", if is_dark { "" } else { "-light" });
                let resource = BundleImageResource::svg(
                    file_name,
                    bundle.to_path_buf(),
                    Some(PathBuf::from("FileIcons")),
                );
                let source = Image::resolve_resource(&resource, size, size);
                AnyView::new(
                    Image::new(source, Size::new(size, size))
                        .content_mode(ImageContentMode::Fit)
                        .rendering_mode(ImageRenderingMode::Color)
                        .accessibility_hidden(true),
                )
            },
        ))
    }
}
