use std::path::Path;

use crate::native_pass_benchmark::NativeValidationError;
use cove_graphics::rhi::{Device, RhiError, RhiResult, Texture, TextureSubresource};
use diffuse_render::RenderDrawableSize;
use serde::{Deserialize, Serialize};

pub enum GridImage {}
impl GridImage {
    pub fn readback(
        device: &Device,
        texture: Texture,
        size: RenderDrawableSize,
    ) -> RhiResult<Vec<u8>> {
        device.wait_until_idle()?;
        let width = size.width as usize;
        let height = size.height as usize;
        let row_bytes = width
            .checked_mul(4)
            .ok_or_else(|| RhiError::invalid_argument("grid image extents overflow"))?;
        let byte_count = row_bytes
            .checked_mul(height)
            .ok_or_else(|| RhiError::invalid_argument("grid image extents overflow"))?;
        let mut data = Vec::new();
        data.try_reserve_exact(byte_count)
            .map_err(|_| RhiError::OutOfMemory)?;
        data.resize(byte_count, 0);
        device.read_texture_data(
            texture,
            width,
            height,
            row_bytes,
            TextureSubresource::default(),
            &mut data,
        )?;
        Ok(data)
    }

    pub fn write_ppm(
        bgra: &[u8],
        size: RenderDrawableSize,
        path: &Path,
    ) -> Result<(), NativeValidationError> {
        if !bgra.len().is_multiple_of(4) {
            return Err(RhiError::invalid_argument("grid image extents differ").into());
        }
        let mut data = format!("P6\n{} {}\n255\n", size.width, size.height).into_bytes();
        for pixel in bgra.as_chunks::<4>().0 {
            data.extend_from_slice(&[pixel[2], pixel[1], pixel[0]]);
        }
        std::fs::write(path, data)?;
        Ok(())
    }

    /// Compare RGB only; alpha neither contributes to the mean nor to outliers.
    pub fn difference(lhs: &[u8], rhs: &[u8]) -> RhiResult<GridImageDifference> {
        if lhs.len() != rhs.len() || lhs.is_empty() || !lhs.len().is_multiple_of(4) {
            return Err(RhiError::invalid_argument("grid image extents differ"));
        }
        let mut absolute = 0_i64;
        let mut maximum = 0_i64;
        let mut outliers = 0_i64;
        for (left, right) in lhs.as_chunks::<4>().0.iter().zip(rhs.as_chunks::<4>().0) {
            let mut delta = 0;
            for channel in 0..3 {
                let difference = (i64::from(left[channel]) - i64::from(right[channel])).abs();
                absolute += difference;
                maximum = maximum.max(difference);
                delta = delta.max(difference);
            }
            if delta > 3 {
                outliers += 1;
            }
        }
        Ok(GridImageDifference {
            mean_absolute_channel_error: absolute as f64 / (lhs.len() / 4 * 3) as f64,
            maximum_channel_error: maximum,
            pixels_over_three: outliers,
            pixel_count: (lhs.len() / 4) as i64,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GridImageDifference {
    pub mean_absolute_channel_error: f64,
    pub maximum_channel_error: i64,
    pub pixels_over_three: i64,
    pub pixel_count: i64,
}
