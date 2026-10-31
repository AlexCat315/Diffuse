//! Portable SHA-256 so pinned downloads can be verified on every host without
//! a platform crypto framework or an external checksum utility.

use std::fs::File;
use std::io::{self, BufReader, Read};
use std::path::Path;

const K: [u32; 64] = [
    0x428a_2f98,
    0x7137_4491,
    0xb5c0_fbcf,
    0xe9b5_dba5,
    0x3956_c25b,
    0x59f1_11f1,
    0x923f_82a4,
    0xab1c_5ed5,
    0xd807_aa98,
    0x1283_5b01,
    0x2431_85be,
    0x550c_7dc3,
    0x72be_5d74,
    0x80de_b1fe,
    0x9bdc_06a7,
    0xc19b_f174,
    0xe49b_69c1,
    0xefbe_4786,
    0x0fc1_9dc6,
    0x240c_a1cc,
    0x2de9_2c6f,
    0x4a74_84aa,
    0x5cb0_a9dc,
    0x76f9_88da,
    0x983e_5152,
    0xa831_c66d,
    0xb003_27c8,
    0xbf59_7fc7,
    0xc6e0_0bf3,
    0xd5a7_9147,
    0x06ca_6351,
    0x1429_2967,
    0x27b7_0a85,
    0x2e1b_2138,
    0x4d2c_6dfc,
    0x5338_0d13,
    0x650a_7354,
    0x766a_0abb,
    0x81c2_c92e,
    0x9272_2c85,
    0xa2bf_e8a1,
    0xa81a_664b,
    0xc24b_8b70,
    0xc76c_51a3,
    0xd192_e819,
    0xd699_0624,
    0xf40e_3585,
    0x106a_a070,
    0x19a4_c116,
    0x1e37_6c08,
    0x2748_774c,
    0x34b0_bcb5,
    0x391c_0cb3,
    0x4ed8_aa4a,
    0x5b9c_ca4f,
    0x682e_6ff3,
    0x748f_82ee,
    0x78a5_636f,
    0x84c8_7814,
    0x8cc7_0208,
    0x90be_fffa,
    0xa450_6ceb,
    0xbef9_a3f7,
    0xc671_78f2,
];

/// Incremental SHA-256 state; 64-byte blocks, big-endian bit length.
pub struct Sha256State {
    h: [u32; 8],
    buffer: Vec<u8>,
    byte_count: u64,
}

impl Sha256State {
    pub const fn new() -> Self {
        Self {
            h: [
                0x6a09_e667,
                0xbb67_ae85,
                0x3c6e_f372,
                0xa54f_f53a,
                0x510e_527f,
                0x9b05_688c,
                0x1f83_d9ab,
                0x5be0_cd19,
            ],
            buffer: Vec::new(),
            byte_count: 0,
        }
    }

    pub fn update(&mut self, data: &[u8]) {
        self.byte_count = self.byte_count.wrapping_add(data.len() as u64);
        self.buffer.extend_from_slice(data);
        while self.buffer.len() >= 64 {
            let block: [u8; 64] = self.buffer[..64].try_into().expect("64-byte block");
            self.compress(&block);
            self.buffer.drain(..64);
        }
    }

    pub fn finalize(mut self) -> [u8; 32] {
        let bit_count = self.byte_count.wrapping_mul(8);
        self.buffer.push(0x80);
        while self.buffer.len() % 64 != 56 {
            self.buffer.push(0);
        }
        for shift in (0..64).step_by(8).rev() {
            self.buffer.push(((bit_count >> shift) & 0xff) as u8);
        }
        while self.buffer.len() >= 64 {
            let block: [u8; 64] = self.buffer[..64].try_into().expect("64-byte block");
            self.compress(&block);
            self.buffer.drain(..64);
        }
        let mut out = [0u8; 32];
        for (index, value) in self.h.iter().enumerate() {
            out[index * 4..index * 4 + 4].copy_from_slice(&value.to_be_bytes());
        }
        out
    }

    fn compress(&mut self, bytes: &[u8; 64]) {
        let mut w = [0u32; 64];
        for (index, chunk) in bytes.as_chunks::<4>().0.iter().enumerate() {
            w[index] = u32::from_be_bytes(*chunk);
        }
        for index in 16..64 {
            let s0 = w[index - 15].rotate_right(7)
                ^ w[index - 15].rotate_right(18)
                ^ (w[index - 15] >> 3);
            let s1 = w[index - 2].rotate_right(17)
                ^ w[index - 2].rotate_right(19)
                ^ (w[index - 2] >> 10);
            w[index] = w[index - 16]
                .wrapping_add(s0)
                .wrapping_add(w[index - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = self.h;
        for index in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[index])
                .wrapping_add(w[index]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        self.h[0] = self.h[0].wrapping_add(a);
        self.h[1] = self.h[1].wrapping_add(b);
        self.h[2] = self.h[2].wrapping_add(c);
        self.h[3] = self.h[3].wrapping_add(d);
        self.h[4] = self.h[4].wrapping_add(e);
        self.h[5] = self.h[5].wrapping_add(f);
        self.h[6] = self.h[6].wrapping_add(g);
        self.h[7] = self.h[7].wrapping_add(h);
    }
}

impl Default for Sha256State {
    fn default() -> Self {
        Self::new()
    }
}

/// Hex digest of an in-memory buffer.
pub fn digest(data: &[u8]) -> [u8; 32] {
    let mut state = Sha256State::new();
    state.update(data);
    state.finalize()
}

/// Lowercase hexadecimal rendering, matching `String(format: "%02x", ...)`.
pub fn hex(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len() * 2);
    for byte in data {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Hex digest of a file read in 1 MiB chunks.
pub fn hex_file(url: &Path) -> io::Result<String> {
    let mut reader = BufReader::new(File::open(url)?);
    let mut state = Sha256State::new();
    let mut chunk = vec![0u8; 1 << 20];
    loop {
        let read = reader.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        state.update(&chunk[..read]);
    }
    Ok(hex(&state.finalize()))
}

/// Convenience namespace mirroring Swift's `SHA256` enum.
pub struct Sha256;

impl Sha256 {
    pub fn hex(data: &[u8]) -> String {
        hex(data)
    }

    pub fn hex_file(url: &Path) -> io::Result<String> {
        hex_file(url)
    }

    pub fn digest(data: &[u8]) -> [u8; 32] {
        digest(data)
    }
}
