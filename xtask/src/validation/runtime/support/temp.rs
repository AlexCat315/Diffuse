//! Temporary-directory creation and log-file access shared by the editor
//! validations.

use crate::support::terminal::ToolError;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Mirror of `tempfile.mkdtemp(prefix:)`: a fresh directory the caller owns and
/// may keep, as `validate-editor-native-loop.py` did.
pub fn directory(prefix: &str) -> Result<PathBuf, ToolError> {
    let url = std::env::temp_dir().join(format!("{prefix}{}", lowercase_uuid()));
    crate::support::files::directory(&url).map_err(io_error)?;
    Ok(url)
}

/// A fresh UUID string in the lowercase spelling `UUID().uuidString` is
/// lowercased into.
fn lowercase_uuid() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed =
        (nanos as u64) ^ (count.wrapping_mul(0x9E37_79B9_7F4A_7C15)) ^ (std::process::id() as u64);
    let a = mixed as u32;
    let b = (mixed >> 32) as u16;
    let c = ((mixed >> 16) & 0x0FFF) as u16 | 0x4000;
    let d = ((mixed >> 48) & 0x3FFF) as u16 | 0x8000;
    let e = mixed.wrapping_mul(6364136223846793005) >> 16;
    format!(
        "{a:08x}-{b:04x}-{c:04x}-{d:04x}-{:012x}",
        e & 0xFFFF_FFFF_FFFF
    )
}

/// Opens (creating or truncating) a file that a child process writes to. The
/// Python originals passed `log.open("wb")` straight to `subprocess.Popen`.
pub fn open_for_writing(url: &Path) -> Result<std::fs::File, ToolError> {
    if let Some(parent) = url.parent() {
        crate::support::files::directory(parent).map_err(io_error)?;
    }
    std::fs::File::create(url).map_err(io_error)
}

/// Reads a child's log back as text, tolerating a write in progress.
pub fn read_text(url: &Path) -> String {
    std::fs::read(url)
        .map(|data| String::from_utf8_lossy(&data).into_owned())
        .unwrap_or_default()
}

/// The Python `text[-8192:]` tails used in failure messages.
pub fn tail(text: &str, count: usize) -> String {
    let characters: Vec<char> = text.chars().collect();
    if characters.len() <= count {
        text.to_string()
    } else {
        characters[characters.len() - count..].iter().collect()
    }
}

fn io_error(error: io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directories_are_unique_and_created() {
        let first = directory("cove-test-").expect("directory");
        let second = directory("cove-test-").expect("directory");
        assert!(first.is_dir());
        assert_ne!(first, second);
        let _ = crate::support::files::remove(&first);
        let _ = crate::support::files::remove(&second);
    }

    #[test]
    fn generated_identifiers_have_the_uuid_shape() {
        let value = lowercase_uuid();
        assert_eq!(value.len(), 36);
        assert_eq!(
            value.split('-').map(str::len).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12]
        );
        assert!(value.chars().all(|c| c.is_ascii_hexdigit() || c == '-'));
    }

    #[test]
    fn tail_keeps_the_last_characters() {
        assert_eq!(tail("abcdef", 3), "def");
        assert_eq!(tail("ab", 3), "ab");
    }

    #[test]
    fn missing_logs_read_as_empty() {
        assert_eq!(read_text(std::path::Path::new("/nonexistent/cove.log")), "");
    }
}
