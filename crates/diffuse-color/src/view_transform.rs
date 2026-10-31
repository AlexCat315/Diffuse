//! `ViewTransform` — exposure/gamma view transform with an OCIO fallback.

use crate::aces_config::ACESConfig;
use crate::ocio_bridge::OCIOBridge;

/// `ViewTransform`.
#[derive(Clone, Debug, PartialEq)]
pub struct ViewTransform {
    pub config: ACESConfig,
    pub exposure: f32,
    pub gamma: f32,
}

impl Default for ViewTransform {
    /// Swift's defaulted initializer: default config, zero exposure, unit gamma.
    fn default() -> Self {
        Self::new(ACESConfig::default(), 0.0, 1.0)
    }
}

impl ViewTransform {
    pub fn new(config: ACESConfig, exposure: f32, gamma: f32) -> Self {
        ViewTransform {
            config,
            exposure,
            gamma,
        }
    }

    /// `ocioDescription(bridge:)`.
    pub fn ocio_description(&self, bridge: Option<&OCIOBridge>) -> String {
        let Some(bridge) = bridge else {
            return "sRGB (passthrough — OCIO unavailable)".to_string();
        };
        if !bridge.is_available() {
            return "sRGB (passthrough — OCIO unavailable)".to_string();
        }
        let from_space = self.config.working_space.raw_value();
        let to_space = self.config.display_transform.raw_value();
        let view_transform = self.config.view_transform.raw_value();
        // Swift interpolates `Float` with `description`, which always shows a
        // fractional part; `{:?}` is the closest Rust equivalent.
        format!(
            "OCIO: {from_space} → {to_space} [{view_transform}] exp={:?} gamma={:?}",
            self.exposure, self.gamma
        )
    }

    /// `apply(to:width:height:using:)`.
    ///
    /// Falls back to the gamma path when OCIO is unavailable and answers `false`
    /// in that case, matching Swift.
    pub fn apply(
        &self,
        pixels: &mut [f32],
        width: usize,
        height: usize,
        bridge: Option<&OCIOBridge>,
    ) -> bool {
        match bridge {
            Some(bridge) if bridge.is_available() => bridge.apply_transform(
                self.config.working_space.raw_value(),
                self.config.display_transform.raw_value(),
                Some(self.config.view_transform.raw_value()),
                None,
                self.exposure,
                self.gamma,
                pixels,
                i32::try_from(width).expect("width does not fit in Int32"),
                i32::try_from(height).expect("height does not fit in Int32"),
            ),
            _ => {
                self.apply_passthrough_gamma(pixels);
                false
            }
        }
    }

    fn apply_passthrough_gamma(&self, pixels: &mut [f32]) {
        if self.gamma == 1.0 {
            return;
        }
        let inverse_gamma = 1.0 / self.gamma.max(0.001);
        let mut index = 0;
        while index < pixels.len() {
            let channels = core::cmp::min(3, pixels.len() - index);
            for channel in 0..channels {
                let value = pixels[index + channel].max(0.0);
                pixels[index + channel] = value.powf(inverse_gamma);
            }
            index += 4;
        }
    }
}
