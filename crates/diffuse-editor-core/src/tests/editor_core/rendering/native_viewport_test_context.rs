//! Ported from `Editor/Tests/EditorCoreTests/Rendering/NativeViewportTestContext.swift`.

use std::rc::Rc;
use std::sync::Arc;

use cove_graphics::rhi::{
    CommandBuffer, Device, DeviceConfig, QueueClass, RenderColorTarget, RenderPassDescriptor,
    RhiResult, TextureDescriptor, TextureFormat, TextureResource, TextureUsage,
};
use cove_graphics::ui::{NativeDrawListRenderer, NativeUIViewport};
use cove_ui_compose::scene_core::{Color, Point, Rect, content_scale, set_content_scale};
use cove_ui_compose::{EmptyView, PrimitiveView};

use super::hud_router::HUDRouter;
use crate::rendering::viewport::viewport_host::ViewportHost;
use diffuse_render::RenderDrawableSize;
use diffuse_render::surface::viewport_image::ViewportImage;
use diffuse_render::surface::viewport_surface::{ViewportSamplingRegion, ViewportSurfaceState};
use diffuse_render_validation::GridImage;
use diffuse_render_validation::SceneCapture;

#[derive(Clone, Copy)]
pub struct ViewportTestOutput {
    pub native: TextureFormat,
    pub samples: usize,
}

impl ViewportTestOutput {
    pub const CASES: [ViewportTestOutput; 4] = [
        ViewportTestOutput {
            native: TextureFormat::Bgra8Unorm,
            samples: 1,
        },
        ViewportTestOutput {
            native: TextureFormat::Bgra8Unorm,
            samples: 4,
        },
        ViewportTestOutput {
            native: TextureFormat::Bgra8UnormSrgb,
            samples: 1,
        },
        ViewportTestOutput {
            native: TextureFormat::Bgra8UnormSrgb,
            samples: 4,
        },
    ];
}

pub struct NativeViewportTestContext {
    pub device: Arc<Device>,
    pub native_ui: NativeDrawListRenderer,
    pub reference: SceneCapture,
    pub hud: HUDRouter,
    pub size: (usize, usize),
}

impl NativeViewportTestContext {
    pub fn new() -> RhiResult<Self> {
        let device = Arc::new(Device::make(DeviceConfig {
            enable_validation: true,
            frames_in_flight: 3,
            ..DeviceConfig::default()
        })?);
        let mut native_ui = NativeDrawListRenderer::new(device.clone())?;
        native_ui.configure(TextureFormat::Bgra8Unorm, 1)?;
        let hud = HUDRouter::new();
        let reference = SceneCapture::new(true, None, Some(Box::new(hud.clone())))?;
        Ok(NativeViewportTestContext {
            device,
            native_ui,
            reference,
            hud,
            size: (384, 256),
        })
    }

    pub fn draw_list(
        &self,
        surface: &ViewportSurfaceState,
    ) -> cove_ui_compose::scene_core::DrawList {
        let scale = content_scale();
        set_content_scale(2.0);
        struct RestoreScale(f32);
        impl Drop for RestoreScale {
            fn drop(&mut self) {
                set_content_scale(self.0);
            }
        }
        let _restore = RestoreScale(scale);

        let aspect_ratio = surface.region.size.width as f32 / surface.region.size.height as f32;
        let host = ViewportHost::new(surface.clone(), EmptyView)
            .content_aspect_ratio(aspect_ratio)
            .on_draw_overlay(Rc::new(|list, frame| {
                let _ = list.add_rounded_rect_stroke(
                    Rect::new(frame.x + 4.0, frame.y + 4.0, 20.0, 12.0),
                    2.0,
                    1.0,
                    Color::WHITE,
                );
            }));
        let node = host.make_node();
        node.set_frame(Rect::new(8.0, 8.0, 176.0, 98.0));
        host.update_node(&node);

        let mut list = cove_ui_compose::scene_core::DrawList::default();
        let _ = list.add_rect(
            Rect::new(0.0, 0.0, 192.0, 128.0),
            Color {
                r: 0.12,
                g: 0.14,
                b: 0.18,
                a: 1.0,
            },
        );
        list.push_clip_rect(Rect::new(10.0, 9.0, 172.0, 96.0));
        if let Some(draw) = node.draw() {
            draw(&mut list, Point::new(0.0, 0.0));
        }
        list.pop_clip_rect();
        let _ = list.add_rounded_rect(
            Rect::new(8.0, 111.0, 65.0, 10.0),
            3.0,
            Color {
                r: 0.2,
                g: 0.5,
                b: 0.8,
                a: 0.8,
            },
        );
        list
    }

    pub fn texture(&self, format: TextureFormat, samples: usize) -> RhiResult<TextureResource> {
        let usage = if samples == 1 {
            TextureUsage::COLOR_TARGET | TextureUsage::SAMPLED | TextureUsage::TRANSFER_SOURCE
        } else {
            TextureUsage::COLOR_TARGET
        };
        TextureResource::new(
            self.device.clone(),
            TextureDescriptor::new(self.size.0, self.size.1, format, usage)
                .with_sample_count(samples),
        )
    }

    pub fn native_image(
        &mut self,
        list: &cove_ui_compose::scene_core::DrawList,
        output: ViewportTestOutput,
    ) -> RhiResult<Vec<u8>> {
        self.native_ui.configure(output.native, output.samples)?;
        let resolved = self.texture(output.native, 1)?;
        let multisampled = if output.samples > 1 {
            Some(self.texture(output.native, output.samples)?)
        } else {
            None
        };
        let mut target = RenderColorTarget::clearing(
            multisampled
                .as_ref()
                .map_or(resolved.texture(), TextureResource::texture),
            [0.0, 0.0, 0.0, 1.0],
        );
        if multisampled.is_some() {
            target.resolve_texture = Some(resolved.texture());
            target.store = false;
        }
        self.device.begin_frame()?;
        let mut commands = CommandBuffer::new();
        let mut frame = self.native_ui.record(
            list,
            &mut commands,
            target,
            NativeUIViewport::new([self.size.0, self.size.1], [192.0, 128.0]),
            None,
        )?;
        let expected = if frame.statistics.texture_uploads == 0 {
            0
        } else {
            4
        };
        assert_eq!(
            frame.statistics.texture_upload_bytes, expected,
            "viewport pixels must not be re-uploaded by the UI"
        );
        let submitted = self
            .device
            .submit(&commands, QueueClass::Graphics, &[], &[], None);
        frame.did_submit();
        self.device.end_frame();
        submitted?;
        GridImage::readback(
            &self.device,
            resolved.texture(),
            RenderDrawableSize::new(self.size.0 as u32, self.size.1 as u32),
        )
    }

    pub fn solid_surface(
        &self,
        color: [f32; 4],
        device: Option<&Arc<Device>>,
    ) -> RhiResult<ViewportSurfaceState> {
        let owner = device.unwrap_or(&self.device);
        let resource = TextureResource::new(
            owner.clone(),
            TextureDescriptor::new(
                4,
                4,
                TextureFormat::Bgra8Unorm,
                TextureUsage::COLOR_TARGET | TextureUsage::SAMPLED,
            ),
        )?;
        owner.begin_frame()?;
        let mut commands = CommandBuffer::new();
        commands.render_pass(
            RenderPassDescriptor::new(vec![RenderColorTarget::clearing(resource.texture(), color)]),
            |_| {},
        );
        let submitted = owner.submit(&commands, QueueClass::Graphics, &[], &[], None);
        owner.end_frame();
        submitted?;
        let size = RenderDrawableSize::new(4, 4);
        Ok(ViewportSurfaceState::with_region(
            1,
            Some(Arc::new(ViewportImage::new(Arc::new(resource), Vec::new()))),
            ViewportSamplingRegion::new(size, size),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solid_surface_records_through_native_ui() {
        // GPU test: needs the deployed `DiffuseRuntime_RenderBackend` bundle.
        if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
            return;
        }
        let mut context = NativeViewportTestContext::new().expect("test context");
        let surface = context
            .solid_surface([1.0, 0.0, 0.0, 1.0], None)
            .expect("solid surface");
        let list = context.draw_list(&surface);
        let pixels = context
            .native_image(&list, ViewportTestOutput::CASES[0])
            .expect("native image");
        assert_eq!(pixels.len(), context.size.0 * context.size.1 * 4);
        let distinct = pixels
            .as_chunks::<4>()
            .0
            .iter()
            .map(|pixel| pixel[0])
            .collect::<std::collections::HashSet<_>>();
        assert!(distinct.len() > 8);
    }
}
