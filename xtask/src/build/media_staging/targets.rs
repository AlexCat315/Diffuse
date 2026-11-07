//! `Targets.swift` — the FFmpeg build matrix: host detection, supported
//! targets, per-target configure flags and the SwiftPM triple each provides.

use std::collections::BTreeMap;
use std::path::Path;

use crate::support::shell;
use crate::support::terminal::ToolError;

pub enum Targets {}

impl Targets {
    pub const SUPPORTED: [&str; 11] = [
        "macos-arm64",
        "macos-x86_64",
        "linux-aarch64",
        "linux-x86_64",
        "windows-arm64",
        "windows-x86_64",
        "android-arm64",
        "android-x86_64",
        "ios-arm64",
        "ios-arm64-simulator",
        "ios-x86_64-simulator",
    ];

    /// Maps the host OS and architecture onto a supported target name.
    pub fn host() -> String {
        let arm = matches!(machine().as_str(), "arm64" | "aarch64");
        host_target(arm).to_string()
    }

    /// The `--arch` applies to every target except the two Apple ones, which
    /// take a clang `-target` triple instead.
    pub fn architecture(name: &str) -> &'static str {
        if name.contains("arm64") || name.contains("aarch64") {
            "aarch64"
        } else {
            "x86_64"
        }
    }

    /// Cross-compilation and toolchain flags for `name`, appended after the
    /// target-independent configure options.
    pub fn options(
        name: &str,
        environment: &BTreeMap<String, String>,
    ) -> Result<Vec<String>, ToolError> {
        let arch = Self::architecture(name);
        let mut options = vec![format!("--arch={arch}")];
        if name.starts_with("ios-") {
            let sdk = if name.ends_with("simulator") {
                "iphonesimulator"
            } else {
                "iphoneos"
            };
            let sysroot = shell::output(
                &[
                    "xcrun".into(),
                    "--sdk".into(),
                    sdk.into(),
                    "--show-sdk-path".into(),
                ],
                None,
                environment,
                false,
            )?;
            let short_arch = if arch == "aarch64" { "arm64" } else { arch };
            let triple = format!(
                "{short_arch}-apple-ios26.0{}",
                if sdk.ends_with("simulator") {
                    "-simulator"
                } else {
                    ""
                }
            );
            let host_root = Self::host_sysroot(environment)?;
            options.extend([
                "--target-os=darwin".into(),
                "--enable-cross-compile".into(),
                "--cc=clang".into(),
                format!("--sysroot={sysroot}"),
                format!("--host-cflags=--sysroot {host_root}"),
                format!("--extra-cflags=-target {triple}"),
                format!("--extra-ldflags=-target {triple}"),
                "--disable-programs".into(),
            ]);
        } else if name.starts_with("android-") {
            let Some(home) = environment
                .get("ANDROID_NDK_HOME")
                .filter(|home| !home.is_empty())
            else {
                return Err(ToolError::message(
                    "Android builds require ANDROID_NDK_HOME for the NDK toolchain",
                ));
            };
            let tools = Path::new(home)
                .join("toolchains/llvm/prebuilt")
                .join(android_toolchain_tag())
                .join("bin");
            let triple = if arch == "aarch64" {
                "aarch64-linux-android"
            } else {
                "x86_64-linux-android"
            };
            options.extend([
                "--target-os=android".into(),
                "--enable-cross-compile".into(),
                format!("--cc={}", tools.join(format!("{triple}28-clang")).display()),
                format!("--ar={}", tools.join("llvm-ar").display()),
                format!("--ranlib={}", tools.join("llvm-ranlib").display()),
                "--disable-programs".into(),
            ]);
            if arch == "x86_64" {
                // Same PIC/inline-asm relocation fix as the x86_64 Linux target.
                options.push("--extra-cflags=-fvisibility=protected".into());
            }
        } else if name.starts_with("windows-") {
            options.extend([
                "--target-os=win32".into(),
                "--toolchain=msvc".into(),
                "--cc=cl".into(),
                "--ar=lib".into(),
                "--disable-x86asm".into(),
            ]);
        } else if name.starts_with("macos-") {
            // A raw toolchain `clang` finds neither headers nor libraries on
            // its own, so the SDK is passed to both compiles and host checks.
            let sysroot = Self::host_sysroot(environment)?;
            let flags = format!(
                "{} -mmacosx-version-min=26.0",
                if arch == "aarch64" { "arm64" } else { arch }
            );
            options.extend([
                "--target-os=darwin".into(),
                "--cc=clang".into(),
                format!("--sysroot={sysroot}"),
                format!("--host-cflags=--sysroot {sysroot}"),
                format!("--extra-cflags=-arch {flags}"),
                format!("--extra-ldflags=-arch {flags}"),
            ]);
        } else {
            options.extend(["--target-os=linux".into(), "--disable-x86asm".into()]);
            // `--enable-pic` makes the x86 CABAC decode emit a PC32 relocation
            // against a preemptible symbol; only x86_64 needs protected
            // visibility, aarch64's ADRP/ADD relocations load natively.
            if arch == "x86_64" {
                options.push("--extra-cflags=-fvisibility=protected".into());
            }
            if name != Self::host() {
                let Some(compiler) = environment
                    .get("COVE_FFMPEG_CC")
                    .filter(|compiler| !compiler.is_empty())
                else {
                    return Err(ToolError::message(
                        "Linux cross builds require COVE_FFMPEG_CC for the target compiler",
                    ));
                };
                options.extend(["--enable-cross-compile".into(), format!("--cc={compiler}")]);
            }
        }
        Ok(options)
    }

    /// The macOS SDK of the build machine, used for configure's host checks.
    pub fn host_sysroot(environment: &BTreeMap<String, String>) -> Result<String, ToolError> {
        shell::output(
            &[
                "xcrun".into(),
                "--sdk".into(),
                "macosx".into(),
                "--show-sdk-path".into(),
            ],
            None,
            environment,
            false,
        )
    }

    /// The SwiftPM-supported triple for `name`.
    pub fn triple(name: &str) -> String {
        if name.starts_with("ios-") {
            let device = name.trim_start_matches("ios-").replace("-simulator", "");
            return format!(
                "{device}-apple-ios{}",
                if name.ends_with("simulator") {
                    "-simulator"
                } else {
                    ""
                }
            );
        }
        let arch = if name.ends_with("arm64") || name.ends_with("aarch64") {
            "aarch64"
        } else {
            "x86_64"
        };
        if name.starts_with("macos-") {
            return format!(
                "{}-apple-macosx",
                if arch == "aarch64" { "arm64" } else { arch }
            );
        }
        let suffix = if name.starts_with("windows-") {
            "unknown-windows-msvc"
        } else if name.starts_with("android-") {
            "unknown-linux-android"
        } else {
            "unknown-linux-gnu"
        };
        format!("{arch}-{suffix}")
    }
}

#[cfg(target_os = "macos")]
fn host_target(arm: bool) -> &'static str {
    if arm { "macos-arm64" } else { "macos-x86_64" }
}

#[cfg(target_os = "windows")]
fn host_target(arm: bool) -> &'static str {
    if arm {
        "windows-arm64"
    } else {
        "windows-x86_64"
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn host_target(arm: bool) -> &'static str {
    if arm { "linux-aarch64" } else { "linux-x86_64" }
}

#[cfg(target_os = "macos")]
fn android_toolchain_tag() -> &'static str {
    "darwin-x86_64"
}

#[cfg(not(target_os = "macos"))]
fn android_toolchain_tag() -> &'static str {
    "linux-x86_64"
}

/// `uname -m`, or `PROCESSOR_ARCHITECTURE` on Windows, lowercased.
#[cfg(windows)]
fn machine() -> String {
    std::env::var("PROCESSOR_ARCHITECTURE")
        .unwrap_or_default()
        .to_lowercase()
}

#[cfg(not(windows))]
fn machine() -> String {
    // SAFETY: `utsname` is a plain POD that `uname` fully initializes. The
    // `machine` field is only read through a byte slice bounded by the array's
    // own length, and no pointer escapes this block.
    unsafe {
        let mut info: libc::utsname = std::mem::zeroed();
        if libc::uname(&mut info) != 0 {
            return String::new();
        }
        let bytes =
            std::slice::from_raw_parts(info.machine.as_ptr().cast::<u8>(), info.machine.len());
        let end = bytes
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(bytes.len());
        String::from_utf8_lossy(&bytes[..end]).to_lowercase()
    }
}
