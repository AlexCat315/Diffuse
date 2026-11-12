//! Ported from `Engine/Tests/EngineCoreTests/PortablePNG.swift`.
//!
//! Minimal, dependency-free PNG (RGBA8) encoder for test fixtures. Uses zlib
//! "stored" (uncompressed) deflate blocks so no compression library is needed and
//! pixels round-trip exactly.

/// Encodes RGBA8 pixels as a PNG the native `stb_image` bridge reads back
/// identically on every platform.
pub fn encode(pixels: &[u8], width: usize, height: usize) -> Vec<u8> {
    assert_eq!(
        pixels.len(),
        width * height * 4,
        "pixels must be RGBA8 (width * height * 4)"
    );

    let mut raw: Vec<u8> = Vec::with_capacity(height * (1 + width * 4));
    for y in 0..height {
        raw.push(0);
        let row_start = y * width * 4;
        raw.extend_from_slice(&pixels[row_start..(row_start + width * 4)]);
    }

    let mut zlib: Vec<u8> = vec![0x78, 0x01];
    let mut offset = 0usize;
    loop {
        let block_len = (raw.len() - offset).min(0xFFFF);
        let is_last = (offset + block_len) >= raw.len();
        zlib.push(if is_last { 0x01 } else { 0x00 });
        zlib.push((block_len & 0xFF) as u8);
        zlib.push(((block_len >> 8) & 0xFF) as u8);
        let nlen = !(block_len as u16);
        zlib.push((nlen & 0xFF) as u8);
        zlib.push(((nlen >> 8) & 0xFF) as u8);
        if block_len > 0 {
            zlib.extend_from_slice(&raw[offset..(offset + block_len)]);
        }
        offset += block_len;
        if offset >= raw.len() {
            break;
        }
    }
    append_be32(&mut zlib, adler32(&raw));

    let mut png: Vec<u8> = vec![137, 80, 78, 71, 13, 10, 26, 10];
    let mut ihdr: Vec<u8> = Vec::new();
    append_be32(&mut ihdr, width as u32);
    append_be32(&mut ihdr, height as u32);
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    append_chunk(&mut png, b"IHDR", &ihdr);
    append_chunk(&mut png, b"IDAT", &zlib);
    append_chunk(&mut png, b"IEND", &[]);
    png
}

fn append_be32(out: &mut Vec<u8>, value: u32) {
    out.push(((value >> 24) & 0xFF) as u8);
    out.push(((value >> 16) & 0xFF) as u8);
    out.push(((value >> 8) & 0xFF) as u8);
    out.push((value & 0xFF) as u8);
}

fn append_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    append_be32(out, data.len() as u32);
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut covered = kind.to_vec();
    covered.extend_from_slice(data);
    append_be32(out, crc32(&covered));
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if (crc & 1) != 0 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    crc ^ 0xFFFF_FFFF
}

fn adler32(bytes: &[u8]) -> u32 {
    let mut a: u32 = 1;
    let mut b: u32 = 0;
    for byte in bytes {
        a = (a + u32::from(*byte)) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}
