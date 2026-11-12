//! `Platforms/Android/Sources/CoveAndroidApp/Content/Game.swift`.
//!
//! Platform-internal seam between the Android host and an exported game. UI
//! applications never depend on the game runtime.

use serde::{Deserialize, Serialize};

use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct GameContentSnapshot {
    pub scripts: i64,
    pub entities: i64,
    pub rendered: bool,
    /// Swift's synthesized `CodingKey` keeps the `ID` spelling.
    #[serde(rename = "surfaceID")]
    pub surface_id: u64,
    pub hud: Vec<String>,
    pub player: Option<[f32; 3]>,
}

pub trait GameContentSession {
    fn surface(&self) -> ViewportSurfaceState;
    fn prepare(&mut self, pixels: (i32, i32), scale: f32, delta_time: f64);
    fn key(&mut self, scancode: u32, down: bool);
    fn release_keys(&mut self);
    fn snapshot(&self) -> GameContentSnapshot;
}
