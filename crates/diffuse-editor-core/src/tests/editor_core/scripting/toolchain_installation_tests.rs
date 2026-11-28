//! `Editor/Tests/EditorCoreTests/Scripting/SwiftToolchainInstallationTests.swift`.
//!
//! Two Swift cases carry over unchanged: a download needs explicit confirmation
//! and must not create its cache before it has one, and preferences round trip
//! separately from the project with missing values defaulting. The Swift
//! installer's `.pkg` signature and download-origin cases have no counterpart:
//! the port installs through `rustup`, which verifies its own release artifacts,
//! so there is no package to inspect here.

use crate::scripting::toolchain::installation::SwiftToolchainInstallation;
use crate::scripting::toolchain::preferences::SwiftToolchainPreferences;
use crate::scripting::toolchain::resolution::SwiftToolchainError;

fn temporary_directory() -> std::path::PathBuf {
    std::env::temp_dir().join(diffuse_kernel::codable::new_uuid())
}

#[test]
fn confirmation_boundary() {
    let root = temporary_directory();
    let installation = SwiftToolchainInstallation::new(root.clone());
    let progress = std::sync::Mutex::new(Vec::new());
    let error = installation
        .install("6.4.1", false, |event| {
            progress
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .push(event);
        })
        .expect_err("unconfirmed install must fail");
    assert!(matches!(error, SwiftToolchainError::ConfirmationRequired));
    assert!(!root.exists());
}

#[test]
fn preferences_round_trip_and_missing_values_default() {
    let root = temporary_directory();
    assert_eq!(
        SwiftToolchainPreferences::load(&root),
        SwiftToolchainPreferences::new()
    );
    let preferences = SwiftToolchainPreferences {
        selected_path: Some("/host/Rust-1.90.0".to_string()),
        release_version: "6.4.0".to_string(),
    };
    preferences.save(&root).expect("save preferences");
    assert_eq!(SwiftToolchainPreferences::load(&root), preferences);

    std::fs::write(
        root.join("preferences.json"),
        br#"{"selectedPath":"/host/Rust-1.90.0"}"#,
    )
    .expect("write partial preferences");
    let partial = SwiftToolchainPreferences::load(&root);
    assert_eq!(partial.selected_path, preferences.selected_path);
    assert_eq!(
        partial.release_version,
        SwiftToolchainPreferences::new().release_version
    );

    let _ = std::fs::remove_dir_all(&root);
}
