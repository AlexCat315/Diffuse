//! Swift's `Data` as it crosses a `Codable` boundary: a base64 string.
//!
//! The plugin RPC carries `input`, `payload` and `arguments` as `Data`, which
//! Swift encoded with Foundation's default `Data` conformance (base64, standard
//! alphabet, padded). `Data` also had to stay `Eq`/`Hash` for handle maps, so
//! this newtype keeps the bytes and spells them the same way.

#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Data(pub Vec<u8>);

impl Data {
    pub fn new() -> Data {
        Data(Vec::new())
    }

    pub fn from_bytes(bytes: impl Into<Vec<u8>>) -> Data {
        Data(bytes.into())
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The base64 text Foundation wrote.
    pub fn base64(&self) -> String {
        encode_base64(&self.0)
    }
}

impl From<Vec<u8>> for Data {
    fn from(value: Vec<u8>) -> Self {
        Data(value)
    }
}

impl From<&[u8]> for Data {
    fn from(value: &[u8]) -> Self {
        Data(value.to_vec())
    }
}

impl From<&str> for Data {
    fn from(value: &str) -> Self {
        Data(value.as_bytes().to_vec())
    }
}

impl AsRef<[u8]> for Data {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

impl serde::Serialize for Data {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&encode_base64(&self.0))
    }
}

impl<'de> serde::Deserialize<'de> for Data {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Data, D::Error> {
        let value = String::deserialize(deserializer)?;
        decode_base64(&value)
            .map(Data)
            .ok_or_else(|| serde::de::Error::custom("invalid base64 data"))
    }
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding, as Foundation writes `Data`.
pub fn encode_base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = chunk.get(1).copied();
        let third = chunk.get(2).copied();
        out.push(ALPHABET[(first >> 2) as usize] as char);
        out.push(
            ALPHABET[(((first & 0b0000_0011) << 4) | (second.unwrap_or(0) >> 4)) as usize] as char,
        );
        match second {
            Some(second) => out.push(
                ALPHABET[(((second & 0b0000_1111) << 2) | (third.unwrap_or(0) >> 6)) as usize]
                    as char,
            ),
            None => out.push('='),
        }
        match third {
            Some(third) => out.push(ALPHABET[(third & 0b0011_1111) as usize] as char),
            None => out.push('='),
        }
    }
    out
}

/// Standard base64 with padding, matching `Data(base64Encoded:)` with no
/// options.
pub fn decode_base64(value: &str) -> Option<Vec<u8>> {
    fn sextet(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes = value.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let padding = chunk.iter().rev().take_while(|byte| **byte == b'=').count();
        if padding > 2 {
            return None;
        }
        let mut buffer: u32 = 0;
        for (index, byte) in chunk.iter().enumerate() {
            let digit = if *byte == b'=' {
                if index < 4 - padding {
                    return None;
                }
                0
            } else {
                sextet(*byte)?
            };
            buffer = (buffer << 6) | u32::from(digit);
        }
        out.push((buffer >> 16) as u8);
        if padding < 2 {
            out.push((buffer >> 8) as u8);
        }
        if padding < 1 {
            out.push(buffer as u8);
        }
    }
    Some(out)
}
