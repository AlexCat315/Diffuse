//! Ported from `Engine/Tests/NativeRendererTests/Support/Device.swift`.
//!
//! Swift's `RendererTestDevice.make(_:)` picks the platform graphics API and, on
//! Windows/Linux, skips the test when no usable Vulkan ICD exists unless
//! `COVE_RUN_GPU_SMOKE_TESTS=1`. Rust has no `XCTSkip`, so the same condition
//! returns `None` and the caller returns early — the case is still exercised
//! where a driver exists, and is never changed into an unconditional skip.

use cove_graphics::rhi::{Device, DeviceConfig, GraphicsApi, RhiResult};

/// `GraphicsAPI` for this build, matching Swift's `#if os(...)` selection.
pub const fn platform_api() -> GraphicsApi {
    #[cfg(target_os = "macos")]
    {
        GraphicsApi::Metal
    }
    #[cfg(target_os = "windows")]
    {
        GraphicsApi::Dx12
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        GraphicsApi::Vulkan
    }
}

/// Whether an explicit GPU regression run was requested.
///
/// Swift's `XCTSkip` for a missing Vulkan ICD: ordinary CI can lack a driver, so
/// a hardware runner says so through `COVE_RUN_GPU_SMOKE_TESTS`.
fn vulkan_runner_is_available() -> bool {
    std::env::var("COVE_RUN_GPU_SMOKE_TESTS").as_deref() == Ok("1")
}

/// `RendererTestDevice.make(_:)` — `None` where Swift would have thrown
/// `XCTSkip`.
pub fn make(config: DeviceConfig) -> RhiResult<Option<Device>> {
    if config.preferred_backends.first() == Some(&GraphicsApi::Vulkan)
        && !vulkan_backend_available()
        && !vulkan_runner_is_available()
    {
        return Ok(None);
    }
    Device::make(config).map(Some)
}

/// `VulkanBackend.isAvailable`. Cove compiles the Vulkan backend on every host
/// and limits only its registration, so this is always callable — unlike Swift,
/// where `canImport(CVulkanHeaders)` decides whether the check exists at all.
fn vulkan_backend_available() -> bool {
    cove_graphics::vulkan::VulkanBackend::is_available()
}

/// `RendererTestDevice.make(DeviceConfig(preferredBackends: [api], enableValidation: false))`.
pub fn make_for(api: GraphicsApi, enable_validation: bool) -> RhiResult<Option<Device>> {
    make(DeviceConfig {
        preferred_backends: vec![api],
        enable_validation,
        ..DeviceConfig::default()
    })
}
