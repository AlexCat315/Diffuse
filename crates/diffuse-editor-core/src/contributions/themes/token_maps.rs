//! `Editor/Sources/EditorCore/Contributions/Themes/TokenMaps.swift`.
//!
//! Swift carried `WritableKeyPath` tables; Rust has no key paths, so each
//! token group resolves by name with the same accepted set. The error for an
//! unknown name names the token, exactly like the Swift table lookup.

use std::collections::BTreeMap;

use cove_ui_compose::scene_core::Color;
use cove_ui_compose::theme::styles::InputAppearance;
use cove_ui_compose::theme::{ColorScheme, RadiusScale, SpacingScale, TextStyleToken, Typography};

use super::theme_resource::ThemeResourceError;

pub struct ThemeTokenMaps;

impl ThemeTokenMaps {
    pub fn apply_colors(
        values: &BTreeMap<String, Color>,
        colors: &mut ColorScheme,
    ) -> Result<(), ThemeResourceError> {
        for (name, value) in values {
            match name.as_str() {
                "background" => colors.background = *value,
                "surface" => colors.surface = *value,
                "surfaceVariant" => colors.surface_variant = *value,
                "surfaceSunken" => colors.surface_sunken = *value,
                "surfaceRaised" => colors.surface_raised = *value,
                "surfaceFloating" => colors.surface_floating = *value,
                "surfaceOverlay" => colors.surface_overlay = *value,
                "onBackground" => colors.on_background = *value,
                "onSurface" => colors.on_surface = *value,
                "onSurfaceVariant" => colors.on_surface_variant = *value,
                "onSurfaceMuted" => colors.on_surface_muted = *value,
                "accent" => colors.accent = *value,
                "accentHover" => colors.accent_hover = *value,
                "accentPressed" => colors.accent_pressed = *value,
                "onAccent" => colors.on_accent = *value,
                "accentMuted" => colors.accent_muted = *value,
                "accentSecondary" => colors.accent_secondary = *value,
                "stateLayerHover" => colors.state_layer_hover = *value,
                "stateLayerPressed" => colors.state_layer_pressed = *value,
                "stateLayerSelected" => colors.state_layer_selected = *value,
                "success" => colors.success = *value,
                "warning" => colors.warning = *value,
                "error" => colors.error = *value,
                "info" => colors.info = *value,
                "border" => colors.border = *value,
                "borderStrong" => colors.border_strong = *value,
                "divider" => colors.divider = *value,
                "focusRing" => colors.focus_ring = *value,
                "selection" => colors.selection = *value,
                "overlay" => colors.overlay = *value,
                _ => return Err(ThemeResourceError::InvalidToken(name.clone())),
            }
        }
        Ok(())
    }

    pub fn apply_typography(
        name: &str,
        token: TextStyleToken,
        typography: &mut Typography,
    ) -> Result<(), ThemeResourceError> {
        match name {
            "display" => typography.display = token,
            "title" => typography.title = token,
            "headline" => typography.headline = token,
            "body" => typography.body = token,
            "bodyStrong" => typography.body_strong = token,
            "caption" => typography.caption = token,
            "label" => typography.label = token,
            "mono" => typography.mono = token,
            _ => return Err(ThemeResourceError::InvalidToken(name.to_owned())),
        }
        Ok(())
    }

    pub fn apply_spacing(
        values: Option<&BTreeMap<String, f32>>,
        spacing: &mut SpacingScale,
    ) -> Result<(), ThemeResourceError> {
        Self::validate_metrics(values)?;
        for (name, value) in values.into_iter().flatten() {
            match name.as_str() {
                "xs" => spacing.xs = *value,
                "sm" => spacing.sm = *value,
                "md" => spacing.md = *value,
                "lg" => spacing.lg = *value,
                "xl" => spacing.xl = *value,
                "xxl" => spacing.xxl = *value,
                _ => return Err(ThemeResourceError::InvalidToken(name.clone())),
            }
        }
        Ok(())
    }

    pub fn apply_radius(
        values: Option<&BTreeMap<String, f32>>,
        radius: &mut RadiusScale,
    ) -> Result<(), ThemeResourceError> {
        Self::validate_metrics(values)?;
        for (name, value) in values.into_iter().flatten() {
            match name.as_str() {
                "none" => radius.none = *value,
                "sm" => radius.sm = *value,
                "md" => radius.md = *value,
                "lg" => radius.lg = *value,
                "xl" => radius.xl = *value,
                "pill" => radius.pill = *value,
                _ => return Err(ThemeResourceError::InvalidToken(name.clone())),
            }
        }
        Ok(())
    }

    pub fn apply_input_colors(
        values: &BTreeMap<String, Color>,
        inputs: &mut InputAppearance,
    ) -> Result<(), ThemeResourceError> {
        for (name, value) in values {
            match name.as_str() {
                "background" => inputs.background = *value,
                "backgroundDisabled" => inputs.background_disabled = *value,
                "borderColor" => inputs.border_color = *value,
                "borderHover" => inputs.border_hover = *value,
                "borderFocused" => inputs.border_focused = *value,
                "borderError" => inputs.border_error = *value,
                "borderDisabled" => inputs.border_disabled = *value,
                "addonBackground" => inputs.addon_background = *value,
                "addonForeground" => inputs.addon_foreground = *value,
                "dividerColor" => inputs.divider_color = *value,
                _ => return Err(ThemeResourceError::InvalidToken(name.clone())),
            }
        }
        Ok(())
    }

    pub fn apply_input_metrics(
        values: Option<&BTreeMap<String, f32>>,
        inputs: &mut InputAppearance,
    ) -> Result<(), ThemeResourceError> {
        Self::validate_metrics(values)?;
        for (name, value) in values.into_iter().flatten() {
            match name.as_str() {
                "borderWidth" => inputs.border_width = *value,
                "focusRingWidth" => inputs.focus_ring_width = *value,
                "radius" => inputs.radius = *value,
                _ => return Err(ThemeResourceError::InvalidToken(name.clone())),
            }
        }
        Ok(())
    }

    fn validate_metrics(values: Option<&BTreeMap<String, f32>>) -> Result<(), ThemeResourceError> {
        if values
            .into_iter()
            .flatten()
            .any(|(_, value)| !value.is_finite() || !(0.0..=1024.0).contains(value))
        {
            return Err(ThemeResourceError::InvalidTheme);
        }
        Ok(())
    }
}
