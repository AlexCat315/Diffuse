//! `ColorPipelineTests` — Swift suite `ColorPipeline`.

use diffuse_color::aces_config::{
    ACESColorSpace, ACESConfig, ACESConfigPreset, ACESDisplayTransform, ACESViewTransform,
};
use diffuse_color::ocio_bridge::OCIOBridge;
use diffuse_color::view_transform::ViewTransform;

// "ACESConfig default is studio preset, ACEScg working space, sRGB display"
#[test]
fn aces_config_defaults() {
    let config = ACESConfig::default();
    assert_eq!(config.config_preset, ACESConfigPreset::Studio);
    assert_eq!(config.working_space, ACESColorSpace::AcesCg);
    assert_eq!(config.display_transform, ACESDisplayTransform::SRgb);
    assert_eq!(config.view_transform, ACESViewTransform::UnToneMapped);
}

// "ACESConfig pipelines a readable description"
#[test]
fn aces_config_description() {
    let config = ACESConfig::new(
        ACESConfigPreset::Studio,
        ACESColorSpace::AcesCg,
        ACESDisplayTransform::SRgb,
        ACESViewTransform::UnToneMapped,
    );
    let description = config.color_pipeline_description();
    assert!(description.contains("studio"));
    assert!(description.contains("ACEScg"));
    assert!(description.contains("sRGB"));
    assert!(description.contains("Un-tone-mapped"));
}

// "ACESConfig preset and color space enums are exhaustive"
#[test]
fn aces_config_enum_exhaustiveness() {
    assert_eq!(ACESConfigPreset::all_cases().len(), 3);
    assert_eq!(ACESColorSpace::all_cases().len(), 4);
    assert_eq!(ACESDisplayTransform::all_cases().len(), 5);
    assert_eq!(ACESViewTransform::all_cases().len(), 4);
}

// "ViewTransform defaults to identity exposure and gamma"
#[test]
fn view_transform_defaults() {
    let view_transform = ViewTransform::default();
    assert_eq!(view_transform.exposure, 0.0);
    assert_eq!(view_transform.gamma, 1.0);
    assert_eq!(view_transform.config.working_space, ACESColorSpace::AcesCg);
}

// "ViewTransform fallback gamma corrects pixel values"
#[test]
fn view_transform_fallback_gamma() {
    let mut pixels: Vec<f32> = vec![0.5, 0.5, 0.5, 1.0, 0.25, 0.25, 0.25, 1.0];
    let view_transform = ViewTransform::new(ACESConfig::default(), 0.0, 2.2);
    let applied = view_transform.apply(&mut pixels, 2, 1, None);
    // OCIO not available, falls back to sRGB gamma.
    assert!(!applied);
    // Gamma-encoded: 0.5^(1/2.2) ≈ 0.73.
    assert!(pixels[0] > 0.5);
    assert!(pixels[4] > 0.25);
}

// "ViewTransform identity gamma leaves pixels unchanged"
#[test]
fn view_transform_identity_gamma() {
    let mut pixels: Vec<f32> = vec![0.5, 0.3, 0.7, 1.0];
    let view_transform = ViewTransform::new(ACESConfig::default(), 0.0, 1.0);
    let _ = view_transform.apply(&mut pixels, 1, 1, None::<&OCIOBridge>);
    assert!((pixels[0] - 0.5).abs() < 0.001);
    assert!((pixels[1] - 0.3).abs() < 0.001);
    assert!((pixels[2] - 0.7).abs() < 0.001);
}

// "OCIOBridge description shows passthrough when unavailable"
#[test]
fn ocio_bridge_unavailable_description() {
    let config = ACESConfig::default();
    let view_transform = ViewTransform::new(config, 0.0, 1.0);
    let description = view_transform.ocio_description(None);
    assert!(description.contains("passthrough"));
    assert!(description.contains("OCIO unavailable"));
}
