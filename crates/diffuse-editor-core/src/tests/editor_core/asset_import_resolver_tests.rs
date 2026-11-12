//! Ported from `Editor/Tests/EditorCoreTests/AssetImportResolverTests.swift`.

use std::path::{Path, PathBuf};

use cove_system::paths::PathIdentity;

use crate::assets::asset_import_resolver::{AssetImportResolver, ResolvedFile};

struct TempDirectory {
    url: PathBuf,
}

impl TempDirectory {
    fn new(prefix: &str) -> Self {
        let url =
            std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()));
        std::fs::create_dir_all(&url).expect("temporary directory");
        TempDirectory { url }
    }

    fn join(&self, relative: &str) -> PathBuf {
        self.url.join(relative)
    }

    fn write(&self, relative: &str, contents: &str) -> PathBuf {
        let url = self.join(relative);
        if let Some(parent) = url.parent() {
            std::fs::create_dir_all(parent).expect("parent directory");
        }
        std::fs::write(&url, contents).expect("fixture file");
        url
    }
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.url);
    }
}

fn relative_paths(files: &[ResolvedFile]) -> Vec<String> {
    files
        .iter()
        .map(|file| file.relative_path.clone())
        .collect()
}

fn try_symlink_dir(target: &Path, link: &Path) -> bool {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).is_ok()
    }
    #[cfg(windows)]
    {
        std::os::windows::fs::symlink_dir(target, link).is_ok()
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (target, link);
        false
    }
}

#[test]
fn native_geometry_is_a_self_contained_model_import() {
    let source = Path::new("/assets/rounded.DMESH");
    assert!(AssetImportResolver::is_supported(source));
    assert!(AssetImportResolver::SUPPORTED_MODEL_EXTENSIONS.contains(&"dmesh"));
    assert_eq!(
        relative_paths(&AssetImportResolver::resolve(source, None)),
        ["rounded.DMESH"]
    );
}

#[test]
fn glb_is_self_contained() {
    let dir = TempDirectory::new("cove-import");
    let glb = dir.write("prop.glb", "binary");

    let resolved = AssetImportResolver::resolve(&glb, None);
    assert_eq!(relative_paths(&resolved), ["prop.glb"]);
}

#[test]
fn gltf_pulls_its_bin_buffer_and_subfolder_textures() {
    let dir = TempDirectory::new("cove-import");
    let gltf = dir.write(
        "lighter.gltf",
        r#"{
  "buffers": [{ "uri": "lighter.bin" }],
  "images": [
    { "uri": "textures/diff.jpg" },
    { "uri": "textures/diff.jpg" },
    { "uri": "data:image/png;base64,AAAA" },
    { "uri": "https://example.com/remote.png" }
  ]
}
"#,
    );

    // Asset first, then deduped external deps; embedded/remote skipped.
    assert_eq!(
        relative_paths(&AssetImportResolver::resolve(&gltf, None)),
        ["lighter.gltf", "lighter.bin", "textures/diff.jpg"]
    );
}

#[test]
fn obj_resolves_mtllib_and_its_texture_maps_stripping_map_options() {
    let dir = TempDirectory::new("cove-import");
    let obj = dir.write(
        "crate.obj",
        r#"mtllib crate.mtl
v 0 0 0
f 1 1 1
"#,
    );
    dir.write(
        "crate.mtl",
        r#"newmtl crate
map_Kd -o 1 1 -s 2 2 textures/crate_diff.png
map_Bump textures/crate_nrm.png
"#,
    );

    assert_eq!(
        relative_paths(&AssetImportResolver::resolve(&obj, None)),
        [
            "crate.obj",
            "crate.mtl",
            "textures/crate_diff.png",
            "textures/crate_nrm.png"
        ]
    );
}

#[test]
fn textures_referenced_by_an_mtl_in_a_subfolder_stay_relative_to_it() {
    let dir = TempDirectory::new("cove-import");
    let obj = dir.write("statue.obj", "mtllib mats/statue.mtl\n");
    dir.write("mats/statue.mtl", "map_Kd wood.png\n");

    assert_eq!(
        relative_paths(&AssetImportResolver::resolve(&obj, None)),
        ["statue.obj", "mats/statue.mtl", "mats/wood.png"]
    );
}

#[test]
fn path_escaping_references_are_rejected() {
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("../secret.png"),
        None
    );
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("/etc/passwd"),
        None
    );
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("C:/Windows/system32"),
        None
    );
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("./textures/ok.png"),
        Some("textures/ok.png".to_string())
    );
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("textures/./ok.png"),
        Some("textures/ok.png".to_string())
    );
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("textures\\ok.png"),
        Some("textures/ok.png".to_string())
    );
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("textures/a..b.png"),
        Some("textures/a..b.png".to_string())
    );
    assert_eq!(
        AssetImportResolver::sanitized_relative_path("buf.bin"),
        Some("buf.bin".to_string())
    );
}

#[test]
fn project_resolution_keeps_parent_dependencies_inside_the_project_boundary() {
    let root = TempDirectory::new("cove-import");
    let project = root.join("project");
    let model = root.write(
        "project/Models/ship.gltf",
        r#"{"buffers":[{"uri":"../Shared/ship.bin"}],"images":[{"uri":"../Shared/missing.png"},{"uri":"../../outside.png"},{"uri":"/etc/passwd"},{"uri":"C:/outside.png"},{"uri":"linked/secret.png"}]}"#,
    );
    root.write("project/Shared/ship.bin", "buffer");
    let external = root.join("external");
    root.write("external/secret.png", "secret");
    // Windows runners may lack the privilege to create directory symlinks; the
    // Swift test substituted a real directory in that case.
    let linked = root.join("project/Models/linked");
    let link_created = try_symlink_dir(&external, &linked);
    if !link_created {
        root.write("project/Models/linked/secret.png", "");
    }

    let files = AssetImportResolver::resolve(&model, Some(&project));
    let mut expected = vec!["ship.gltf", "../Shared/ship.bin", "../Shared/missing.png"];
    if !link_created {
        expected.push("linked/secret.png");
    }
    assert_eq!(relative_paths(&files), expected);
    assert!(PathIdentity::same_location(
        &files[1].source,
        &project.join("Shared/ship.bin")
    ));
    assert!(!files[2].source.exists());
    assert!(
        !AssetImportResolver::resolve(&model, None)
            .iter()
            .any(|file| file.relative_path.starts_with(".."))
    );

    let obj = root.write("project/Models/ship.obj", "mtllib ../Materials/ship.mtl");
    root.write("project/Materials/ship.mtl", "map_Kd ../Shared/color.png");
    assert_eq!(
        relative_paths(&AssetImportResolver::resolve(&obj, Some(&project))),
        ["ship.obj", "../Materials/ship.mtl", "../Shared/color.png"]
    );
}

#[test]
fn supported_format_gate() {
    assert!(AssetImportResolver::is_supported(Path::new("a/model.gltf")));
    assert!(AssetImportResolver::is_supported(Path::new("a/model.GLB")));
    assert!(AssetImportResolver::is_supported(Path::new("a/model.obj")));
    assert!(AssetImportResolver::is_supported(Path::new("a/smoke.png")));
    assert!(AssetImportResolver::is_supported(Path::new("a/smoke.WEBP")));
    assert!(AssetImportResolver::is_supported(Path::new("a/vector.svg")));
    assert!(!AssetImportResolver::is_supported(Path::new(
        "a/model.blend"
    )));
    assert!(!AssetImportResolver::is_supported(Path::new(
        "a/archive.zip"
    )));
}

#[test]
fn texture_import_is_self_contained() {
    let dir = TempDirectory::new("cove-import");
    let texture = dir.write("smoke.png", "image");

    let resolved = AssetImportResolver::resolve(&texture, None);
    assert_eq!(relative_paths(&resolved), ["smoke.png"]);
}
