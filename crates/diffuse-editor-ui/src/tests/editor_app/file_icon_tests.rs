//! Ported from `Editor/Tests/EditorAppTests/FileIconTests.swift`.

use std::collections::BTreeSet;

use cove_platform::ResourceBundle;
use diffuse_editor_core::contributions::languages::LanguageCatalog;

use crate::panels::documents::kind::DocumentKind;

fn editor_core_bundle() -> Option<ResourceBundle> {
    ResourceBundle::beside_executable(&[
        "DiffuseEditor_EditorCore",
        "DiffuseEditor_EditorCore.resources",
    ])
    .ok()
    .flatten()
}

fn bundled_languages() -> &'static LanguageCatalog {
    LanguageCatalog::bundled()
}

fn editor_ui_bundle() -> Option<ResourceBundle> {
    ResourceBundle::beside_executable(&[
        "DiffuseEditor_EditorUI",
        "DiffuseEditor_EditorUI.resources",
    ])
    .ok()
    .flatten()
}

/// Common files map to their language and icon; whole names win over
/// extensions.
#[test]
fn common_files_map_to_language_and_icon() {
    if editor_core_bundle().is_none() {
        // Swift resolves these titles through the bundled language plugins;
        // a checkout without the deployed EditorCore resource bundle has none.
        return;
    }
    let languages = bundled_languages();
    let expected: [(&str, &str, &str); 15] = [
        ("Scripts/Player.swift", "Swift", "swift"),
        ("notes.txt", "Plain Text", "text"),
        ("docs/guide.md", "Markdown", "markdown"),
        ("paper.tex", "LaTeX", "latex"),
        ("README.md", "Markdown", "readme"),
        ("LICENSE", "Plain Text", "license"),
        ("Makefile", "Makefile", "makefile"),
        ("CMakeLists.txt", "CMake", "cmake"),
        ("package.json", "JSON", "package-json"),
        ("textures/albedo.png", "Image", "image"),
        ("models/hero.glb", "3D Model", "3d"),
        (".gitignore", "Git", "git"),
        ("data.bin", "Binary", "binary"),
        ("unknown.qqq", "QQQ", "file"),
        ("NOEXTENSION", "Plain Text", "text"),
    ];
    for (path, name, icon) in expected {
        let kind = DocumentKind::new(path, languages);
        assert_eq!(kind.name, name, "{path}");
        assert_eq!(kind.icon_key, icon, "{path}");
    }
}

/// Every icon a path can resolve to ships in both the dark and light variant.
#[test]
fn every_icon_is_bundled() {
    let Some(bundle) = editor_ui_bundle() else {
        return;
    };
    if editor_core_bundle().is_none() {
        return;
    }
    let languages = bundled_languages();
    let paths = [
        "a.swift",
        "a.md",
        "a.txt",
        "a.tex",
        "a.svg",
        "a.png",
        "a.mp4",
        "a.wav",
        "a.ttf",
        "a.glb",
        "a.pdf",
        "a.zip",
        "a.bin",
        "a.exe",
        "a.db",
        "a.qqq",
        "README",
        "LICENSE",
        "Makefile",
        "CMakeLists.txt",
        "Dockerfile",
        "package.json",
        "Package.resolved",
        ".gitignore",
        ".env",
        ".npmrc",
        "build.ninja",
        "build.gradle",
    ];
    let mut keys: BTreeSet<String> = paths
        .iter()
        .map(|path| DocumentKind::new(path, languages).icon_key)
        .collect();
    keys.insert("folder".to_string());
    keys.insert("folder_open".to_string());
    for key in keys {
        for suffix in ["", "-light"] {
            let name = format!("filetype-{key}{suffix}.svg");
            assert!(
                bundle.root().join(&name).is_file(),
                "missing bundled icon {name}"
            );
        }
    }
}
