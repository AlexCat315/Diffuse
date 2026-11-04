//! The editor pass pair: grid and geometry overlay.

use std::sync::Arc;

use cove_graphics::rhi::{Device, RhiResult};

use crate::native::passes::native_editor_grid_pass::NativeEditorGridPass;
use crate::native::passes::native_geometry_overlay_pass::NativeGeometryOverlayPass;

pub struct NativeEditorPasses {
    pub grid: NativeEditorGridPass,
    pub geometry: NativeGeometryOverlayPass,
}

impl NativeEditorPasses {
    pub fn new(device: &Arc<Device>) -> RhiResult<Self> {
        let grid = NativeEditorGridPass::new(device)?;
        let geometry = NativeGeometryOverlayPass::new(device)?;
        Ok(NativeEditorPasses { grid, geometry })
    }
}
