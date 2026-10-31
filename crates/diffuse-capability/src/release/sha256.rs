//! Dependency-free SHA-256 used for stable capability contract fingerprints.
//!
//! Swift hand-rolled the digest to stay Foundation-free; Rust keeps the same
//! implementation so fingerprints stay byte-identical (MIGRATION.md §5.7 bans
//! new crates for this).

const CONSTANTS: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

#[inline]
fn rotate_right(value: u32, amount: u32) -> u32 {
    value.rotate_right(amount)
}

/// SHA-256 digest bytes.
pub fn digest(message: &[u8]) -> [u8; 32] {
    let mut hash: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    let mut bytes = message.to_vec();
    let bit_count = (bytes.len() as u64).wrapping_mul(8);
    bytes.push(0x80);
    while bytes.len() % 64 != 56 {
        bytes.push(0);
    }
    for index in (0..8).rev() {
        bytes.push(((bit_count >> ((index as u64) * 8)) & 0xff) as u8);
    }

    let mut words = [0u32; 64];
    let mut chunk = 0;
    while chunk < bytes.len() {
        // Mirrors Swift's `for index in 0..<16` indexing directly; the offset and
        // index are the same quantity here.
        #[allow(clippy::needless_range_loop)]
        for index in 0..16 {
            let offset = chunk + index * 4;
            words[index] = (u32::from(bytes[offset]) << 24)
                | (u32::from(bytes[offset + 1]) << 16)
                | (u32::from(bytes[offset + 2]) << 8)
                | u32::from(bytes[offset + 3]);
        }
        for index in 16..64 {
            let s0 = rotate_right(words[index - 15], 7)
                ^ rotate_right(words[index - 15], 18)
                ^ (words[index - 15] >> 3);
            let s1 = rotate_right(words[index - 2], 17)
                ^ rotate_right(words[index - 2], 19)
                ^ (words[index - 2] >> 10);
            words[index] = words[index - 16]
                .wrapping_add(s0)
                .wrapping_add(words[index - 7])
                .wrapping_add(s1);
        }

        let (mut a, mut b, mut c, mut d) = (hash[0], hash[1], hash[2], hash[3]);
        let (mut e, mut f, mut g, mut h) = (hash[4], hash[5], hash[6], hash[7]);
        for index in 0..64 {
            let s1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
            let choice = (e & f) ^ (!e & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(choice)
                .wrapping_add(CONSTANTS[index])
                .wrapping_add(words[index]);
            let s0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        hash[0] = hash[0].wrapping_add(a);
        hash[1] = hash[1].wrapping_add(b);
        hash[2] = hash[2].wrapping_add(c);
        hash[3] = hash[3].wrapping_add(d);
        hash[4] = hash[4].wrapping_add(e);
        hash[5] = hash[5].wrapping_add(f);
        hash[6] = hash[6].wrapping_add(g);
        hash[7] = hash[7].wrapping_add(h);
        chunk += 64;
    }

    let mut out = [0u8; 32];
    for (index, value) in hash.iter().enumerate() {
        out[index * 4] = ((value >> 24) & 0xff) as u8;
        out[index * 4 + 1] = ((value >> 16) & 0xff) as u8;
        out[index * 4 + 2] = ((value >> 8) & 0xff) as u8;
        out[index * 4 + 3] = (value & 0xff) as u8;
    }
    out
}

/// Lowercase hex digest, matching Swift's `String(format: "%02x", $0)` join.
pub fn capability_sha256_hex_digest(data: &[u8]) -> String {
    let bytes = digest(data);
    let mut out = String::with_capacity(64);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

pub enum CapabilityDigest {}

impl CapabilityDigest {
    #[inline]
    pub fn sha256(data: &[u8]) -> String {
        capability_sha256_hex_digest(data)
    }
}
