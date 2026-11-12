//! Ported from `Editor/Tests/GameRuntimeTests/PlayerInstallValidatorTests.swift`.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::player_install_validator::{PlayerInstallValidationError, PlayerInstallValidator};

const RESOURCE_BUNDLE_BASES: [&str; 5] = PlayerInstallValidator::RESOURCE_BUNDLE_BASES;

static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

fn executable_name() -> &'static str {
    if cfg!(windows) {
        "CovePlayer.exe"
    } else {
        "CovePlayer"
    }
}

fn temporary_root() -> PathBuf {
    let unique = NEXT_ROOT.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let root = std::env::temp_dir().join(format!(
        "cove-player-install-{}-{nanos}-{unique}",
        std::process::id()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    root
}

fn make_executable(path: &Path) {
    std::fs::write(path, b"player").expect("executable");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("mode");
    }
}

fn create_resource_bundle(root: &Path, name: &str, suffix: &str) {
    std::fs::create_dir_all(root.join(format!("{name}.{suffix}"))).expect("resource bundle");
}

fn make_portable_layout() -> PathBuf {
    let root = temporary_root();
    make_executable(&root.join(executable_name()));
    for base in RESOURCE_BUNDLE_BASES {
        create_resource_bundle(&root, base, "bundle");
    }
    root
}

#[test]
fn portable_layout_accepts_bundle_and_resources_directories() {
    let root = make_portable_layout();
    std::fs::remove_dir_all(root.join("CoveUICompose_CoveUICompose.bundle")).expect("remove");
    create_resource_bundle(&root, "CoveUICompose_CoveUICompose", "resources");

    let report =
        PlayerInstallValidator::validate_layout(Some(&root.join(executable_name())), None, &[])
            .expect("valid layout");

    assert!(report.contains("5 resource bundles"));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn missing_resources_are_reported_together() {
    let root = make_portable_layout();
    std::fs::remove_dir_all(root.join("DiffuseRuntime_RenderBackend.bundle")).expect("remove");
    std::fs::remove_dir_all(root.join("CoveUI_CoveUI.bundle")).expect("remove");

    let error =
        PlayerInstallValidator::validate_layout(Some(&root.join(executable_name())), None, &[])
            .expect_err("missing resources");
    match error {
        PlayerInstallValidationError::MissingComponents(missing) => assert_eq!(
            missing,
            [
                "CoveUI_CoveUI.{bundle,resources}",
                "DiffuseRuntime_RenderBackend.{bundle,resources}",
            ]
        ),
        other => panic!("unexpected error: {other}"),
    }
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn command_line_fallback_locates_executable() {
    let root = make_portable_layout();
    let executable = root.join(executable_name());

    PlayerInstallValidator::validate_layout(
        None,
        None,
        &[executable.to_string_lossy().into_owned()],
    )
    .expect("command-line executable");
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(target_os = "macos")]
#[test]
fn mac_application_looks_for_resources_in_contents_resources() {
    let root = temporary_root();
    let app = root.join("My Game.app");
    let executable = app.join("Contents/MacOS/My Game");
    std::fs::create_dir_all(executable.parent().expect("macos directory")).expect("directories");
    make_executable(&executable);
    write_application_info_plist(&app, "My Game");
    for base in RESOURCE_BUNDLE_BASES {
        create_resource_bundle(&app.join("Contents/Resources"), base, "bundle");
    }

    PlayerInstallValidator::validate_layout(Some(&executable), None, &[]).expect("valid app");
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(target_os = "macos")]
#[test]
fn mac_application_rejects_missing_info_plist() {
    let root = temporary_root();
    let app = root.join("My Game.app");
    let executable = app.join("Contents/MacOS/My Game");
    std::fs::create_dir_all(executable.parent().expect("macos directory")).expect("directories");
    make_executable(&executable);
    for base in RESOURCE_BUNDLE_BASES {
        create_resource_bundle(&app.join("Contents/Resources"), base, "bundle");
    }

    let error = PlayerInstallValidator::validate_layout(Some(&executable), None, &[])
        .expect_err("missing Info.plist");
    match error {
        PlayerInstallValidationError::MissingComponents(missing) => {
            assert!(missing.iter().any(|item| item == "Contents/Info.plist"))
        }
        other => panic!("unexpected error: {other}"),
    }
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(target_os = "macos")]
fn write_application_info_plist(app: &Path, executable: &str) {
    let contents = app.join("Contents");
    std::fs::create_dir_all(&contents).expect("contents");
    let plist = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
         <key>CFBundleExecutable</key><string>{executable}</string>\
         <key>CFBundlePackageType</key><string>APPL</string>\
         </dict></plist>"
    );
    std::fs::write(contents.join("Info.plist"), plist).expect("Info.plist");
}
