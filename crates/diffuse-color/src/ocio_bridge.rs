//! Stub OCIO bridge. The native OpenColorIO library is no longer linked into the
//! engine — colour space transforms fall back to the gamma path in
//! [`crate::view_transform::ViewTransform`]. The public API is preserved so
//! callers do not need to change.

/// `OCIOBridge`. Unreachable by construction: `new` always answers `None`, and
/// every query reports the bridge as unavailable.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OCIOBridge;

impl OCIOBridge {
    /// `init?(configPath:)` — always fails while OCIO is not linked.
    pub fn new(_config_path: &str) -> Option<Self> {
        None
    }

    /// `isAvailable`.
    pub fn is_available(&self) -> bool {
        false
    }

    /// `colorSpaceNames`.
    pub fn color_space_names(&self) -> Vec<String> {
        Vec::new()
    }

    /// `applyTransform(inputColorSpace:outputColorSpace:viewTransform:display:exposure:gamma:to:width:height:)`.
    #[allow(clippy::too_many_arguments)]
    pub fn apply_transform(
        &self,
        _input_color_space: &str,
        _output_color_space: &str,
        _view_transform: Option<&str>,
        _display: Option<&str>,
        _exposure: f32,
        _gamma: f32,
        _pixels: &mut [f32],
        _width: i32,
        _height: i32,
    ) -> bool {
        false
    }
}
