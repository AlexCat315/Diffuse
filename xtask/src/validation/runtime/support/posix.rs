//! Raw descriptor IO with deadlines.
//!
//! Swift's `POSIXIO` wrapped `poll(2)`/`read(2)`/`write(2)` behind
//! `Darwin`/`Glibc` imports. The Rust port calls the same libc entry points, so
//! readiness and partial-read semantics are byte-for-byte the same.
//!
//! # Safety boundary
//!
//! Every function here takes a raw descriptor. The caller owns it and must keep
//! it open for the duration of the call; these helpers never close anything.

use crate::support::terminal::ToolError;

pub struct PosixIo;

impl PosixIo {
    pub const SOCK_STREAM: i32 = libc::SOCK_STREAM;

    pub fn close(descriptor: i32) {
        // SAFETY: the caller owns `descriptor` and this is the single close.
        unsafe {
            libc::close(descriptor);
        }
    }

    /// Descriptors that are readable, hung up or in error within `timeout`.
    pub fn readable(descriptors: &[i32], timeout: f64) -> Result<Vec<i32>, ToolError> {
        Self::ready(descriptors, libc::POLLIN, timeout)
    }

    pub fn writable(descriptor: i32, timeout: f64) -> Result<bool, ToolError> {
        Ok(!Self::ready(&[descriptor], libc::POLLOUT, timeout)?.is_empty())
    }

    fn ready(descriptors: &[i32], events: i16, timeout: f64) -> Result<Vec<i32>, ToolError> {
        if descriptors.is_empty() {
            return Ok(Vec::new());
        }
        let millis = ((timeout.max(0.0) * 1000.0).ceil() as i64).clamp(0, i32::MAX as i64) as i32;
        let mut entries: Vec<libc::pollfd> = descriptors
            .iter()
            .map(|descriptor| libc::pollfd {
                fd: *descriptor,
                events,
                revents: 0,
            })
            .collect();
        // SAFETY: `entries` is a live, exclusively borrowed buffer of the length
        // passed as `nfds`; `poll` only writes `revents` into it.
        let ready = unsafe { libc::poll(entries.as_mut_ptr(), entries.len() as libc::nfds_t, millis) };
        if ready < 0 {
            let code = std::io::Error::last_os_error();
            if code.raw_os_error() == Some(libc::EINTR) {
                return Ok(Vec::new());
            }
            return Err(ToolError::message(format!("poll failed: {code}")));
        }
        if ready == 0 {
            return Ok(Vec::new());
        }
        Ok(descriptors
            .iter()
            .zip(entries.iter())
            .filter(|(_, entry)| entry.revents != 0)
            .map(|(descriptor, _)| *descriptor)
            .collect())
    }

    /// One read; `None` means end of file.
    pub fn read(descriptor: i32, up_to: usize) -> Option<Vec<u8>> {
        let mut buffer = vec![0u8; up_to];
        // SAFETY: the buffer is live and its length is passed as the capacity.
        let received = unsafe { libc::read(descriptor, buffer.as_mut_ptr().cast(), buffer.len()) };
        if received <= 0 {
            return None;
        }
        buffer.truncate(received as usize);
        Some(buffer)
    }

    pub fn write(descriptor: i32, data: &[u8]) -> Result<(), ToolError> {
        let mut offset = 0;
        while offset < data.len() {
            // SAFETY: `offset` is always within `data`, so the pointer and the
            // remaining length describe a valid subslice.
            let written = unsafe {
                libc::write(
                    descriptor,
                    data[offset..].as_ptr().cast(),
                    data.len() - offset,
                )
            };
            if written < 0 {
                let code = std::io::Error::last_os_error();
                if code.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                return Err(ToolError::message(format!("write failed: {code}")));
            }
            offset += written as usize;
        }
        Ok(())
    }

    pub fn error_text(code: i32) -> String {
        // SAFETY: `strerror` returns a pointer to a process-owned C string for
        // any integer code; it is only read here.
        unsafe {
            let message = libc::strerror(code);
            if message.is_null() {
                return format!("errno {code}");
            }
            std::ffi::CStr::from_ptr(message)
                .to_string_lossy()
                .into_owned()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::PosixIo;

    #[test]
    fn writing_and_reading_a_pipe_round_trips() {
        let mut descriptors = [0i32; 2];
        // SAFETY: `descriptors` holds room for two integers, as `pipe` requires.
        assert_eq!(unsafe { libc::pipe(descriptors.as_mut_ptr()) }, 0);
        let (read_end, write_end) = (descriptors[0], descriptors[1]);
        PosixIo::write(write_end, b"hello").expect("write");
        PosixIo::close(write_end);
        assert!(PosixIo::readable(&[read_end], 1.0).expect("ready").contains(&read_end));
        assert_eq!(PosixIo::read(read_end, 64).as_deref(), Some(&b"hello"[..]));
        // A closed write end reports end of file rather than an empty read.
        assert!(PosixIo::read(read_end, 64).is_none());
        PosixIo::close(read_end);
    }

    #[test]
    fn empty_descriptor_sets_are_never_ready() {
        assert!(PosixIo::readable(&[], 1.0).expect("ready").is_empty());
    }
}
