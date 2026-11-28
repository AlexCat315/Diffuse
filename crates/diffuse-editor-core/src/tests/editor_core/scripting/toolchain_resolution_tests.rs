//! `Editor/Tests/EditorCoreTests/Scripting/SwiftToolchainResolutionTests.swift`.
//!
//! The port tracks the Rust toolchain the editor compiles scripts with, so the
//! fixture builds a `bin/` of `rustc`, `cargo` and `rust-analyzer` instead of a
//! Swift installation. The three cases are unchanged: a paired selection fixes
//! every path and launch variable together, an explicit override wins over
//! persisted paths while a mismatched analyzer fails closed, and a missing
//! analyzer is never silently replaced by another installation.

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod tests {
    use std::collections::BTreeMap;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    use crate::scripting::rust_analyzer::server::executable_locator::RustAnalyzerExecutableLocator;
    use crate::scripting::toolchain::preferences::SwiftToolchainPreferences;
    use crate::scripting::toolchain::resolution::{SwiftToolchainError, SwiftToolchainResolver};

    struct Fixture {
        root: PathBuf,
        environment: BTreeMap<String, String>,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "cove-toolchain-{}",
                diffuse_kernel::codable::new_uuid()
            ));
            let binaries = root.join("bin");
            let sysroot = root.join("sysroot");
            fs::create_dir_all(&binaries).expect("create bin");
            fs::create_dir_all(&sysroot).expect("create sysroot");
            let compiler = binaries.join("rustc");
            write_script(
                &compiler,
                &format!(
                    "#!/bin/sh\ncase \"$1\" in\n  --print) printf '%s' '{}' ;;\n  --version) printf '%s' 'rustc 1.90.0 (fixture)' ;;\n*) exit 0 ;;\nesac\n",
                    sysroot.display()
                ),
            );
            write_script(&binaries.join("cargo"), "#!/bin/sh\nexit 0\n");
            write_script(&binaries.join("rust-analyzer"), "#!/sh\nexit 0\n");
            let mut environment = BTreeMap::new();
            environment.insert("PATH".to_string(), "/usr/bin:/bin".to_string());
            Fixture { root, environment }
        }

        fn compiler(&self) -> PathBuf {
            self.root.join("bin").join("rustc")
        }

        fn language_server(&self) -> PathBuf {
            self.root.join("bin").join("rust-analyzer")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn write_script(path: &Path, body: &str) {
        fs::write(path, body).expect("write script");
        let mut permissions = fs::metadata(path).expect("stat script").permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("chmod script");
    }

    #[test]
    fn paired_selection_fixes_every_path_and_launch_variable() {
        let fixture = Fixture::new();
        let toolchain = SwiftToolchainResolver::resolve(
            Some(&fixture.root.to_string_lossy()),
            &fixture.environment,
            &SwiftToolchainPreferences::default(),
        )
        .expect("resolve paired toolchain");
        assert_eq!(toolchain.compiler_url, fixture.compiler());
        assert_eq!(toolchain.language_server_url, fixture.language_server());
        assert_eq!(toolchain.root_url, fixture.root);
        assert_eq!(
            toolchain.environment.get("RUSTUP_TOOLCHAIN"),
            Some(&fixture.root.to_string_lossy().into_owned())
        );
        assert_eq!(
            toolchain.environment.get("RUSTC"),
            Some(&fixture.compiler().to_string_lossy().into_owned())
        );
        assert!(
            toolchain
                .environment
                .get("PATH")
                .is_some_and(|value| value.starts_with(
                    &fixture.root.join("bin").to_string_lossy().into_owned()
                ))
        );
    }

    #[test]
    fn explicit_compiler_beats_persisted_paths_and_mismatched_analyzer_fails_closed() {
        let fixture = Fixture::new();
        let preferences = SwiftToolchainPreferences {
            selected_path: Some("/missing/persisted/path".to_string()),
            ..SwiftToolchainPreferences::default()
        };
        let toolchain = SwiftToolchainResolver::resolve(
            Some(&fixture.root.to_string_lossy()),
            &fixture.environment,
            &preferences,
        )
        .expect("explicit compiler wins");
        assert_eq!(toolchain.root_url, fixture.root);

        let mut mismatched = fixture.environment.clone();
        mismatched.insert(
            RustAnalyzerExecutableLocator::OVERRIDE_ENVIRONMENT_KEY.to_string(),
            "/bin/sh".to_string(),
        );
        let error = SwiftToolchainResolver::resolve(
            Some(&fixture.root.to_string_lossy()),
            &mismatched,
            &SwiftToolchainPreferences::default(),
        )
        .expect_err("mismatched analyzer must fail");
        assert!(matches!(error, SwiftToolchainError::Unavailable(_)));
    }

    #[test]
    fn missing_paired_analyzer_is_never_silently_replaced() {
        let fixture = Fixture::new();
        fs::remove_file(fixture.language_server()).expect("remove analyzer");
        let error = SwiftToolchainResolver::resolve(
            Some(&fixture.root.to_string_lossy()),
            &fixture.environment,
            &SwiftToolchainPreferences::default(),
        )
        .expect_err("missing analyzer must fail");
        assert!(matches!(error, SwiftToolchainError::Unavailable(_)));
    }
}
