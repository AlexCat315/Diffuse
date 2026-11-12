//! Ported from `Editor/Tests/EditorAppTests/ReleaseInstallValidatorTests.swift`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::launch_options::EditorAppLaunchOptions;
use crate::release_install_validator::{EditorInstallValidationError, EditorInstallValidator};

const BUNDLE_BASES: [&str; 6] = EditorInstallValidator::RESOURCE_BUNDLE_BASES;

static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

fn temporary_root() -> PathBuf {
    let unique = NEXT_ROOT.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let root = std::env::temp_dir().join(format!(
        "cove-install-{}-{nanos}-{unique}",
        std::process::id()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    root
}

fn make_executable(path: &Path) {
    std::fs::write(path, b"").expect("executable");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("mode");
    }
}

fn create_resource_bundle(name: &str, root: &Path) {
    std::fs::create_dir_all(root.join(format!("{name}.bundle"))).expect("resource bundle");
}

fn make_layout(is_windows: bool) -> PathBuf {
    let root = temporary_root();
    std::fs::create_dir_all(root.join("Tools")).expect("tools directory");
    let suffix = if is_windows { ".exe" } else { "" };
    for path in [
        format!("EditorApp{suffix}"),
        format!("CovePlayer{suffix}"),
        format!("Tools/DiffusePluginHost{suffix}"),
        format!("Tools/DiffuseMCP{suffix}"),
    ] {
        make_executable(&root.join(path));
    }
    for base in BUNDLE_BASES {
        create_resource_bundle(base, &root);
    }
    root
}

/// Complete portable layout passes on POSIX and Windows.
#[test]
fn complete_portable_layout_passes_on_posix_and_windows() {
    let platforms: &[bool] = if cfg!(windows) {
        &[true]
    } else {
        &[false, true]
    };
    for is_windows in platforms {
        let root = make_layout(*is_windows);
        let executable = root.join(if *is_windows {
            "EditorApp.exe"
        } else {
            "EditorApp"
        });
        let report = EditorInstallValidator::validate_editor_layout(
            Some(&executable),
            None,
            &[],
            *is_windows,
        )
        .expect("valid layout");
        assert!(report.contains("4 executables"));
        assert!(report.contains("6 resource bundles"));
        let _ = std::fs::remove_dir_all(root);
    }
}

/// Missing player and resource bundle are reported together.
#[test]
fn missing_player_and_resource_bundle_are_reported_together() {
    let is_windows = cfg!(windows);
    let (player_name, editor_name) = if is_windows {
        ("CovePlayer.exe", "EditorApp.exe")
    } else {
        ("CovePlayer", "EditorApp")
    };
    let root = make_layout(is_windows);
    std::fs::remove_file(root.join(player_name)).expect("remove player");
    std::fs::remove_dir_all(root.join("CoveUICompose_CoveUICompose.bundle"))
        .expect("remove bundle");

    let error = EditorInstallValidator::validate_editor_layout(
        Some(&root.join(editor_name)),
        None,
        &[],
        is_windows,
    )
    .expect_err("missing components");
    match error {
        EditorInstallValidationError::MissingComponents(missing) => {
            assert!(missing.iter().any(|item| item == player_name));
            assert!(
                missing
                    .iter()
                    .any(|item| item == "CoveUICompose_CoveUICompose.{bundle,resources}")
            );
        }
        other => panic!("unexpected error: {other}"),
    }
    let _ = std::fs::remove_dir_all(root);
}

/// Command-line executable fallback supports platforms without bundle URL.
#[test]
fn command_line_executable_fallback() {
    let root = make_layout(true);
    let executable = root.join("EditorApp.exe");
    EditorInstallValidator::validate_editor_layout(
        None,
        None,
        &[executable.to_string_lossy().into_owned()],
        true,
    )
    .expect("command-line executable");
    let _ = std::fs::remove_dir_all(root);
}

/// Non-executable POSIX companion is rejected.
#[cfg(unix)]
#[test]
fn non_executable_posix_companion_is_rejected() {
    use std::os::unix::fs::PermissionsExt;

    let root = make_layout(false);
    let player = root.join("CovePlayer");
    std::fs::set_permissions(&player, std::fs::Permissions::from_mode(0o644)).expect("mode");

    let error = EditorInstallValidator::validate_editor_layout(
        Some(&root.join("EditorApp")),
        None,
        &[],
        false,
    )
    .expect_err("non-executable companion");
    match error {
        EditorInstallValidationError::MissingComponents(missing) => {
            assert!(missing.iter().any(|item| item == "CovePlayer"));
        }
        other => panic!("unexpected error: {other}"),
    }
    let _ = std::fs::remove_dir_all(root);
}

/// Launch options recognize validation mode.
#[test]
fn launch_options_recognize_validation_mode() {
    let options = EditorAppLaunchOptions::load(
        &["EditorApp".to_string(), "--validate-install".to_string()],
        &BTreeMap::new(),
    )
    .expect("launch options");
    assert!(options.validate_install);
}

#[cfg(target_os = "macos")]
fn make_application_bundle(root: &Path) -> (PathBuf, PathBuf) {
    let app = root.join("DiffuseEditor.app");
    let macos = app.join("Contents/MacOS");
    let helpers = app.join("Contents/Helpers");
    std::fs::create_dir_all(&macos).expect("macos directory");
    std::fs::create_dir_all(&helpers).expect("helpers directory");
    write_application_info_plist(&app, "EditorApp");
    for url in [
        macos.join("EditorApp"),
        macos.join("CovePlayer"),
        helpers.join("DiffusePluginHost"),
        helpers.join("DiffuseMCP"),
    ] {
        make_executable(&url);
    }
    for base in BUNDLE_BASES {
        create_resource_bundle(base, &app.join("Contents/Resources"));
    }
    (app, macos)
}

#[cfg(target_os = "macos")]
fn write_application_info_plist(app: &Path, executable: &str) {
    let plist = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
         <key>CFBundleExecutable</key><string>{executable}</string>\
         <key>CFBundlePackageType</key><string>APPL</string>\
         </dict></plist>"
    );
    std::fs::write(app.join("Contents/Info.plist"), plist).expect("Info.plist");
}

#[cfg(target_os = "macos")]
#[test]
fn mac_application_bundle_layout_passes() {
    let root = temporary_root();
    let (_app, macos) = make_application_bundle(&root);
    EditorInstallValidator::validate_editor_layout(
        Some(&macos.join("EditorApp")),
        None,
        &[],
        false,
    )
    .expect("mac application bundle");
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(target_os = "macos")]
#[test]
fn mac_application_bundle_rejects_missing_plugin_runtime() {
    let root = temporary_root();
    let (app, macos) = make_application_bundle(&root);
    std::fs::remove_file(app.join("Contents/Helpers/DiffusePluginHost"))
        .expect("remove plugin host");
    let error = EditorInstallValidator::validate_editor_layout(
        Some(&macos.join("EditorApp")),
        None,
        &[],
        false,
    )
    .expect_err("missing plugin host");
    match error {
        EditorInstallValidationError::MissingComponents(missing) => assert!(
            missing
                .iter()
                .any(|item| item == "Contents/Helpers/DiffusePluginHost")
        ),
        other => panic!("unexpected error: {other}"),
    }
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(target_os = "macos")]
#[test]
fn mac_application_bundle_rejects_invalid_info_plist() {
    let root = temporary_root();
    let (app, macos) = make_application_bundle(&root);
    std::fs::write(app.join("Contents/Info.plist"), "not-a-plist").expect("invalid plist");
    let error = EditorInstallValidator::validate_editor_layout(
        Some(&macos.join("EditorApp")),
        None,
        &[],
        false,
    )
    .expect_err("invalid plist");
    match error {
        EditorInstallValidationError::MissingComponents(missing) => {
            assert!(missing.iter().any(|item| item == "Contents/Info.plist"))
        }
        other => panic!("unexpected error: {other}"),
    }
    let _ = std::fs::remove_dir_all(root);
}
