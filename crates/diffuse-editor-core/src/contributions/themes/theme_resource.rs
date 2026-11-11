//! `Editor/Sources/EditorCore/Contributions/Themes/ThemeResource.swift`.
//!
//! A theme package ships one JSON resource per theme. `version` gates the
//! format; each variant is validated before the catalog hands it out, so a
//! broken theme fails at registration rather than at first paint.

use std::collections::BTreeMap;

use cove_ui_compose::scene_core::{Color, Font, FontDesign, FontWeight, SurfaceShadow};
use cove_ui_compose::theme::{Easing, Theme};
use serde::de::Error as _;
use serde::{Deserialize, Deserializer};

use super::editor_theme_tokens::EditorThemeTokens;
use super::token_maps::ThemeTokenMaps;

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ThemeResourceError {
    #[error("invalid theme resource")]
    InvalidTheme,
    #[error("invalid theme token: {0}")]
    InvalidToken(String),
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ThemeResource {
    pub version: i64,
    pub light: Option<ThemeVariant>,
    pub dark: Option<ThemeVariant>,
}

impl ThemeResource {
    pub fn validate(&self, appearance: &str) -> Result<(), ThemeResourceError> {
        let both = self.light.is_some() && self.dark.is_some();
        if self.version != 1
            || !(self.light.is_some() || self.dark.is_some())
            || (appearance == "dual" && !both)
            || (appearance == "light" && self.light.is_none())
            || (appearance == "dark" && self.dark.is_none())
        {
            return Err(ThemeResourceError::InvalidTheme);
        }
        if let Some(light) = &self.light {
            light.make(false)?;
        }
        if let Some(dark) = &self.dark {
            dark.make(true)?;
        }
        Ok(())
    }
}

/// A color written either as `#RRGGBB` / `#RRGGBBAA` or as four RGBA floats in
/// `0...1`. Swift accepted both spellings in one `Decodable` initializer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ThemeColor {
    pub value: Color,
}

impl<'de> Deserialize<'de> for ThemeColor {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        match value {
            serde_json::Value::String(text) => {
                let characters: Vec<char> = text.chars().collect();
                let length = characters.len();
                if characters.first() == Some(&'#')
                    && (length == 7 || length == 9)
                    && let Ok(rgba) = u32::from_str_radix(&text[1..], 16)
                {
                    let has_alpha = length == 9;
                    let red = ((rgba >> if has_alpha { 24 } else { 16 }) & 0xFF) as u8;
                    let green = ((rgba >> if has_alpha { 16 } else { 8 }) & 0xFF) as u8;
                    let blue = ((rgba >> if has_alpha { 8 } else { 0 }) & 0xFF) as u8;
                    let alpha = if has_alpha { (rgba & 0xFF) as u8 } else { 255 };
                    return Ok(ThemeColor {
                        value: Color::from_rgba8(red, green, blue, alpha),
                    });
                }
                Err(D::Error::custom(ThemeResourceError::InvalidTheme))
            }
            serde_json::Value::Array(values) => {
                let mut channels = Vec::with_capacity(values.len());
                for value in &values {
                    match value.as_f64() {
                        Some(number) => channels.push(number as f32),
                        None => return Err(D::Error::custom(ThemeResourceError::InvalidTheme)),
                    }
                }
                if channels.len() != 4
                    || !channels
                        .iter()
                        .all(|channel| channel.is_finite() && (0.0..=1.0).contains(channel))
                {
                    return Err(D::Error::custom(ThemeResourceError::InvalidTheme));
                }
                Ok(ThemeColor {
                    value: Color {
                        r: channels[0],
                        g: channels[1],
                        b: channels[2],
                        a: channels[3],
                    },
                })
            }
            _ => Err(D::Error::custom(ThemeResourceError::InvalidTheme)),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeFont {
    pub size: f32,
    pub line_height: f32,
    pub weight: Option<String>,
    pub monospaced: Option<bool>,
    pub family: Option<String>,
}

impl ThemeFont {
    pub fn token(&self) -> Result<cove_ui_compose::theme::TextStyleToken, ThemeResourceError> {
        if !self.size.is_finite()
            || !(1.0..=128.0).contains(&self.size)
            || !self.line_height.is_finite()
            || !(1.0..=256.0).contains(&self.line_height)
            || self
                .family
                .as_ref()
                .is_some_and(|family| family.chars().count() > 128)
        {
            return Err(ThemeResourceError::InvalidTheme);
        }
        let weight = match self.weight.as_deref().unwrap_or("regular") {
            "regular" => FontWeight::Regular,
            "medium" => FontWeight::Medium,
            "semibold" => FontWeight::Semibold,
            "bold" => FontWeight::Bold,
            _ => return Err(ThemeResourceError::InvalidTheme),
        };
        Ok(cove_ui_compose::theme::TextStyleToken::new(
            Font::new(
                self.size,
                weight,
                if self.monospaced == Some(true) {
                    FontDesign::Monospaced
                } else {
                    FontDesign::Standard
                },
                self.family.clone(),
                false,
            ),
            self.line_height,
            0.0,
        ))
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ThemeMotion {
    pub fast: i64,
    pub standard: i64,
    pub slow: i64,
    pub easing: String,
}

impl ThemeMotion {
    pub fn apply(&self, theme: &mut Theme) -> Result<(), ThemeResourceError> {
        if ![self.fast, self.standard, self.slow]
            .iter()
            .all(|value| (0..=10_000).contains(value))
        {
            return Err(ThemeResourceError::InvalidTheme);
        }
        // Swift stored milliseconds; Cove's motion scale is in seconds.
        theme.motion.fast = self.fast as f64 / 1000.0;
        theme.motion.standard = self.standard as f64 / 1000.0;
        theme.motion.slow = self.slow as f64 / 1000.0;
        theme.motion.standard_easing = match self.easing.as_str() {
            "standard" => Easing::STANDARD,
            "emphasized" => Easing::EMPHASIZED,
            "decelerate" => Easing::DECELERATE,
            "accelerate" => Easing::cubic_bezier(0.4, 0.0, 1.0, 1.0),
            _ => return Err(ThemeResourceError::InvalidTheme),
        };
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeShadow {
    pub color: ThemeColor,
    pub offset_x: f32,
    pub offset_y: f32,
    pub blur: f32,
}

impl ThemeShadow {
    pub fn token(&self) -> Result<SurfaceShadow, ThemeResourceError> {
        if ![self.offset_x, self.offset_y, self.blur]
            .iter()
            .all(|value| value.is_finite())
            || self.offset_x.abs() > 128.0
            || self.offset_y.abs() > 128.0
            || !(0.0..=256.0).contains(&self.blur)
        {
            return Err(ThemeResourceError::InvalidTheme);
        }
        Ok(SurfaceShadow {
            color: Some(self.color.value),
            offset_x: self.offset_x,
            offset_y: self.offset_y,
            blur: self.blur,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ThemeInputTokens {
    pub colors: Option<BTreeMap<String, ThemeColor>>,
    pub metrics: Option<BTreeMap<String, f32>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeVariant {
    pub colors: Option<BTreeMap<String, ThemeColor>>,
    pub typography: Option<BTreeMap<String, ThemeFont>>,
    pub spacing: Option<BTreeMap<String, f32>>,
    pub radius: Option<BTreeMap<String, f32>>,
    pub motion: Option<ThemeMotion>,
    pub inputs: Option<ThemeInputTokens>,
    pub text_emphasis: Option<BTreeMap<String, ThemeColor>>,
    pub shadow: Option<ThemeShadow>,
    pub assistant: Option<ThemeColor>,
    pub syntax: Option<BTreeMap<String, ThemeColor>>,
}

impl ThemeVariant {
    pub fn make(&self, dark: bool) -> Result<Theme, ThemeResourceError> {
        let mut theme = if dark {
            Theme::default_dark()
        } else {
            Theme::default_light()
        };
        if let Some(colors) = &self.colors {
            let colors: BTreeMap<String, Color> = colors
                .iter()
                .map(|(name, color)| (name.clone(), color.value))
                .collect();
            ThemeTokenMaps::apply_colors(&colors, &mut theme.colors)?;
        }
        for (name, font) in self.typography.iter().flatten() {
            ThemeTokenMaps::apply_typography(name, font.token()?, &mut theme.typography)?;
        }
        ThemeTokenMaps::apply_spacing(self.spacing.as_ref(), &mut theme.spacing)?;
        ThemeTokenMaps::apply_radius(self.radius.as_ref(), &mut theme.radius)?;
        if let Some(motion) = &self.motion {
            motion.apply(&mut theme)?;
        }
        if let Some(inputs) = &self.inputs {
            if let Some(colors) = &inputs.colors {
                let colors: BTreeMap<String, Color> = colors
                    .iter()
                    .map(|(name, color)| (name.clone(), color.value))
                    .collect();
                ThemeTokenMaps::apply_input_colors(&colors, &mut theme.inputs)?;
            }
            ThemeTokenMaps::apply_input_metrics(inputs.metrics.as_ref(), &mut theme.inputs)?;
        }
        for (name, color) in self.text_emphasis.iter().flatten() {
            match name.as_str() {
                "placeholder" => theme.text_emphasis.placeholder = Some(color.value),
                "disabled" => theme.text_emphasis.disabled = Some(color.value),
                _ => return Err(ThemeResourceError::InvalidToken(name.clone())),
            }
        }
        if let Some(shadow) = &self.shadow {
            theme.elevation.low = shadow.token()?;
        }
        if let Some(assistant) = &self.assistant {
            let mut tokens = theme.extensions.get::<EditorThemeTokens>();
            tokens.assistant = assistant.value;
            theme.extensions.set(tokens);
        }
        for (name, color) in self.syntax.iter().flatten() {
            if diffuse_plugin::contribution::languages::language::SyntaxToken::from_raw_value(name)
                .is_none()
            {
                return Err(ThemeResourceError::InvalidToken(name.clone()));
            }
            let mut tokens = theme.extensions.get::<EditorThemeTokens>();
            tokens.syntax.insert(name.clone(), color.value);
            theme.extensions.set(tokens);
        }
        Ok(theme)
    }
}
