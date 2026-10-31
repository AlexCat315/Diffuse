//! Top-to-bottom, straight RGBA bytes, independent of the host graphics stack.

use crate::support::terminal::ToolError;
use std::ffi::c_uchar;
use std::os::raw::c_int;

unsafe extern "C" {
    fn cove_tool_decode_image(
        data: *const c_uchar,
        count: c_int,
        width: *mut c_int,
        height: *mut c_int,
    ) -> *mut c_uchar;
    fn cove_tool_free_image(pixels: *mut c_uchar);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodedImage {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl DecodedImage {
    pub fn from_data(data: &[u8]) -> Result<Self, ToolError> {
        let count = i32::try_from(data.len())
            .ok()
            .filter(|count| *count > 0)
            .ok_or_else(|| {
                ToolError::message("Image data is empty or too large to decode")
            })?;
        let mut width: c_int = 0;
        let mut height: c_int = 0;
        // SAFETY: `data` is a live slice whose length is passed as `count`, and
        // both output integers are valid for the duration of the call.
        let buffer = unsafe {
            cove_tool_decode_image(data.as_ptr(), count, &mut width, &mut height)
        };
        if buffer.is_null() {
            return Err(ToolError::message("Cannot decode screenshot image"));
        }
        let length = width as usize * height as usize * 4;
        // SAFETY: the bridge returns a buffer of exactly width*height*4 bytes
        // for a successful decode, owned by the bridge until freed below.
        let pixels = unsafe { std::slice::from_raw_parts(buffer, length).to_vec() };
        // SAFETY: `buffer` came from `cove_tool_decode_image` and is freed once.
        unsafe { cove_tool_free_image(buffer) };
        Ok(Self {
            width: width as usize,
            height: height as usize,
            pixels,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::DecodedImage;

    // Swift: testPNGKeepsRowOrderAndUnpremultipliedColor.
    #[test]
    fn a_png_keeps_row_order_and_unpremultiplied_colour() {
        let png = decode_base64(
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR4nAXBAQEAAACCIKb33EAkQxUHQdUHepwfNGcAAAAASUVORK5CYII=",
        );
        let image = DecodedImage::from_data(&png).expect("decodes");
        assert_eq!(image.width, 2);
        assert_eq!(image.height, 2);
        assert_eq!(
            image.pixels,
            [255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 0]
        );
    }

    // Swift: testMalformedImageFailsInsteadOfProducingBlankPixels.
    #[test]
    fn malformed_images_fail_instead_of_producing_blank_pixels() {
        assert!(DecodedImage::from_data(&[]).is_err());
        assert!(DecodedImage::from_data(b"not a PNG").is_err());
    }

    /// A tiny standard-alphabet base64 decoder, so the test needs no crate.
    fn decode_base64(text: &str) -> Vec<u8> {
        let mut output = Vec::new();
        let mut accumulator = 0u32;
        let mut bits = 0u32;
        for byte in text.bytes() {
            let value = match byte {
                b'A'..=b'Z' => byte - b'A',
                b'a'..=b'z' => byte - b'a' + 26,
                b'0'..=b'9' => byte - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                b'=' | b'\n' | b'\r' => continue,
                _ => panic!("invalid base64 character"),
            } as u32;
            accumulator = (accumulator << 6) | value;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                output.push((accumulator >> bits) as u8);
            }
        }
        output
    }

    #[test]
    fn the_base64_helper_round_trips_known_input() {
        assert_eq!(decode_base64("Zm9vYmFy"), b"foobar".to_vec());
    }
}
