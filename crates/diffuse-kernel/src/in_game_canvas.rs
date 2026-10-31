//! In-game immediate-mode 2D canvas: colors, draw commands and the per-frame
//! command list a game script fills in.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InGameUIColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl InGameUIColor {
    #[inline]
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        InGameUIColor { r, g, b, a }
    }

    /// Swift's default alpha is 1.
    #[inline]
    pub const fn opaque(r: f32, g: f32, b: f32) -> Self {
        InGameUIColor { r, g, b, a: 1.0 }
    }

    pub const WHITE: InGameUIColor = InGameUIColor::opaque(1.0, 1.0, 1.0);
    pub const BLACK: InGameUIColor = InGameUIColor::opaque(0.0, 0.0, 0.0);
    pub const RED: InGameUIColor = InGameUIColor::opaque(1.0, 0.0, 0.0);
    pub const GREEN: InGameUIColor = InGameUIColor::opaque(0.0, 0.8, 0.0);
    pub const BLUE: InGameUIColor = InGameUIColor::opaque(0.0, 0.4, 1.0);
    pub const YELLOW: InGameUIColor = InGameUIColor::opaque(1.0, 0.9, 0.0);
    pub const CLEAR: InGameUIColor = InGameUIColor::new(0.0, 0.0, 0.0, 0.0);

    #[inline]
    pub const fn gray(brightness: f32) -> Self {
        InGameUIColor::opaque(brightness, brightness, brightness)
    }

    #[inline]
    pub const fn gray_with_alpha(brightness: f32, alpha: f32) -> Self {
        InGameUIColor::new(brightness, brightness, brightness, alpha)
    }
}

/// A single draw command emitted by a game script into the overlay canvas.
#[derive(Clone, Debug, PartialEq)]
pub enum InGameCanvasCommand {
    Label {
        text: String,
        x: f32,
        y: f32,
        font_size: f32,
        color: InGameUIColor,
    },
    Rect {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: InGameUIColor,
        corner_radius: f32,
    },
    ProgressBar {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        value: f32,
        max_value: f32,
        fill_color: InGameUIColor,
        bg_color: InGameUIColor,
        corner_radius: f32,
    },
}

/// Per-frame immediate-mode 2D canvas for in-game UI.
///
/// Coordinates are in logical points (top-left origin). The HUD host maps its
/// logical viewport to drawable pixels. Scripts emit commands each tick; the
/// render packet carries that tick's canvas value.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InGameCanvas {
    pub commands: Vec<InGameCanvasCommand>,
}

impl InGameCanvas {
    #[inline]
    pub fn new() -> Self {
        InGameCanvas {
            commands: Vec::new(),
        }
    }

    /// Swift defaults: `fontSize: 16`, `color: .white`.
    #[inline]
    pub fn label(&mut self, text: impl Into<String>, x: f32, y: f32) {
        self.label_styled(text, x, y, 16.0, InGameUIColor::WHITE);
    }

    #[inline]
    pub fn label_styled(
        &mut self,
        text: impl Into<String>,
        x: f32,
        y: f32,
        font_size: f32,
        color: InGameUIColor,
    ) {
        self.commands.push(InGameCanvasCommand::Label {
            text: text.into(),
            x,
            y,
            font_size,
            color,
        });
    }

    /// Swift default: `cornerRadius: 0`.
    #[inline]
    pub fn rect(&mut self, x: f32, y: f32, w: f32, h: f32, color: InGameUIColor) {
        self.rect_rounded(x, y, w, h, color, 0.0);
    }

    #[inline]
    pub fn rect_rounded(
        &mut self,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: InGameUIColor,
        corner_radius: f32,
    ) {
        self.commands.push(InGameCanvasCommand::Rect {
            x,
            y,
            w,
            h,
            color,
            corner_radius,
        });
    }

    /// Swift defaults: `maxValue: 1`, the green fill, the 0.15 grey background
    /// with 0.85 alpha, and `cornerRadius: 3`.
    #[inline]
    pub fn progress_bar(&mut self, x: f32, y: f32, w: f32, h: f32, value: f32) {
        self.progress_bar_styled(
            x,
            y,
            w,
            h,
            value,
            1.0,
            Self::DEFAULT_FILL_COLOR,
            Self::DEFAULT_BG_COLOR,
            3.0,
        );
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    pub fn progress_bar_styled(
        &mut self,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        value: f32,
        max_value: f32,
        fill_color: InGameUIColor,
        bg_color: InGameUIColor,
        corner_radius: f32,
    ) {
        self.commands.push(InGameCanvasCommand::ProgressBar {
            x,
            y,
            w,
            h,
            value,
            max_value,
            fill_color,
            bg_color,
            corner_radius,
        });
    }

    pub const DEFAULT_FILL_COLOR: InGameUIColor = InGameUIColor::opaque(0.2, 0.8, 0.2);
    pub const DEFAULT_BG_COLOR: InGameUIColor = InGameUIColor::new(0.15, 0.15, 0.15, 0.85);
}
