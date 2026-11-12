//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/ViewportTargetAllocationTests.swift`.

use cove_graphics::rhi::{BindingType, GraphicsApi, ShaderStage};
use diffuse_render::native::targets::native_shader_library::NativeShaderLibrary;
use diffuse_render::{RenderDrawableSize, ViewportTargetAllocation, ViewportTargetSizing};

/// The post shaders need the deployed resource bundle.
fn resource_bundle_available() -> bool {
    std::env::var_os("COVE_RESOURCE_PATH").is_some()
}

/// Oversized targets shrink after settling; growth and resizing stay immediate.
#[test]
fn settled_allocations_shrink() {
    let mut sizing = ViewportTargetSizing::new();
    let large = RenderDrawableSize::new(2048, 2048);
    let small = RenderDrawableSize::new(500, 400);
    assert_eq!(sizing.capacity(large, small, 0.0), large);
    assert_eq!(sizing.capacity(large, small, 0.5), large);
    assert_eq!(
        sizing.capacity(large, small, 1.0),
        RenderDrawableSize::new(512, 512)
    );

    let mut dragging = ViewportTargetSizing::new();
    assert_eq!(dragging.capacity(large, small, 0.0), large);
    let next = RenderDrawableSize::new(700, 400);
    assert_eq!(dragging.capacity(large, next, 0.9), large);
    assert_eq!(dragging.capacity(large, next, 1.5), large);
    assert_eq!(
        dragging.capacity(large, next, 2.0),
        RenderDrawableSize::new(768, 512)
    );
    let grown = dragging.capacity(large, RenderDrawableSize::new(2500, 100), 2.1);
    assert_eq!(grown, RenderDrawableSize::new(2560, 2048));
}

/// Quantizes up to the allocation granularity.
#[test]
fn quantizes_up() {
    assert_eq!(ViewportTargetAllocation::quantized(1), 256);
    assert_eq!(ViewportTargetAllocation::quantized(255), 256);
    assert_eq!(ViewportTargetAllocation::quantized(256), 256);
    assert_eq!(ViewportTargetAllocation::quantized(257), 512);
    assert_eq!(ViewportTargetAllocation::quantized(0), 256);
    assert_eq!(
        ViewportTargetAllocation::quantized(u32::MAX),
        ViewportTargetAllocation::MAX_DIMENSION
    );
}

/// Reuses the current capacity while it fits.
#[test]
fn reuses_capacity() {
    let current = RenderDrawableSize::new(1536, 1024);
    assert_eq!(
        ViewportTargetAllocation::grown_capacity(current, RenderDrawableSize::new(800, 600)),
        current
    );
    assert_eq!(
        ViewportTargetAllocation::grown_capacity(current, current),
        current
    );

    let grown_width =
        ViewportTargetAllocation::grown_capacity(current, RenderDrawableSize::new(1600, 600));
    assert_eq!(grown_width, RenderDrawableSize::new(1792, 1024));
    let grown_height =
        ViewportTargetAllocation::grown_capacity(current, RenderDrawableSize::new(100, 1100));
    assert_eq!(grown_height, RenderDrawableSize::new(1536, 1280));
}

/// Initial allocation starts from the quantized used size.
#[test]
fn initial_allocation() {
    let grown = ViewportTargetAllocation::grown_capacity(
        RenderDrawableSize::new(0, 0),
        RenderDrawableSize::new(1400, 800),
    );
    assert_eq!(grown, RenderDrawableSize::new(1536, 1024));
}

/// Clamps the used extent to hardware-safe bounds.
#[test]
fn clamps_used() {
    assert_eq!(
        ViewportTargetAllocation::clamped_used(RenderDrawableSize::new(0, 0)),
        RenderDrawableSize::new(1, 1)
    );
    assert_eq!(
        ViewportTargetAllocation::clamped_used(RenderDrawableSize::new(u32::MAX, 4)),
        RenderDrawableSize::new(ViewportTargetAllocation::MAX_DIMENSION, 4)
    );
}

/// Fullscreen post artifacts bind the viewport sub-region uniform.
#[test]
fn post_shaders_carry_sub_region_uniforms() {
    if !resource_bundle_available() {
        return;
    }

    for api in [GraphicsApi::Metal, GraphicsApi::Vulkan] {
        for name in [
            "tonemap",
            "fxaa",
            "bloom",
            "taa",
            "ssao",
            "ssr",
            "ink_paper_post",
        ] {
            let shader = NativeShaderLibrary::artifact(name, api, ShaderStage::Fragment)
                .unwrap_or_else(|error| panic!("{api:?} {name}: {error}"));
            let frame = shader
                .interface
                .bindings
                .iter()
                .find(|binding| binding.name == "frame")
                .unwrap_or_else(|| panic!("{api:?} {name} has no frame binding"));
            assert_eq!(frame.binding_type, BindingType::UniformBuffer);
            shader
                .binding_layout_descriptor(frame.space)
                .unwrap_or_else(|error| panic!("{api:?} {name} layout: {error}"));
        }
    }
}
