//! Game content exchanged between the player and the Android host.

use diffuse_render::RenderDrawableSize;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GameContentSnapshot {
    pub scripts: i64,
    pub entities: i64,
    pub rendered: bool,
    #[serde(rename = "surfaceID")]
    pub surface_id: u64,
    pub hud: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub player: Option<[f32; 3]>,
}

pub trait GameContentSession {
    fn surface(&self) -> &ViewportSurfaceState;
    fn prepare(&mut self, pixels: RenderDrawableSize, scale: f32, delta_time: f64);
    fn key(&mut self, scancode: u32, down: bool);
    fn release_keys(&mut self);
    fn snapshot(&self) -> GameContentSnapshot;
}
