//! `Editor/Sources/EditorCore/Rendering/HUD/AtlasDelivery.swift`.

use cove_ui_compose::scene_core::GlyphAtlasFormat;
use cove_ui_compose::scene_core::scene::{DrawListAtlasDirty, DrawListSnapshot};

/// Retains atlas planes consumed from the snapshot channel until a renderer
/// accepts ownership. Upload/record/submit retries then belong to that renderer.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct InGameUIAtlasDelivery {
    /// Swift keys this on `GlyphAtlasFormat`; `GlyphAtlasFormat` is not `Ord`
    /// in Rust, so the pairs keep insertion order with replace-on-insert.
    pending: Vec<(GlyphAtlasFormat, DrawListAtlasDirty)>,
}

impl InGameUIAtlasDelivery {
    pub fn collect(&mut self, snapshot: &DrawListSnapshot) {
        for update in &snapshot.atlas_updates {
            self.insert(update.format, update.clone());
        }
    }

    /// Uploads each pending plane in `alpha`, `color` order; a successful
    /// upload releases that plane.
    pub fn stage<E>(
        &mut self,
        mut upload: impl FnMut(&DrawListAtlasDirty) -> Result<(), E>,
    ) -> Result<(), E> {
        for format in [GlyphAtlasFormat::Alpha, GlyphAtlasFormat::Color] {
            let Some(position) = self
                .pending
                .iter()
                .position(|(pending, _)| *pending == format)
            else {
                continue;
            };
            upload(&self.pending[position].1)?;
            self.pending.remove(position);
        }
        Ok(())
    }

    fn insert(&mut self, format: GlyphAtlasFormat, update: DrawListAtlasDirty) {
        match self
            .pending
            .iter_mut()
            .find(|(pending, _)| *pending == format)
        {
            Some(entry) => entry.1 = update,
            None => self.pending.push((format, update)),
        }
    }
}
