//! Line framing for stderr chunks delivered by the shared process service.
//!
//! Ported from `Engine/Sources/PluginRuntime/Host/Diagnostics.swift`. The Swift
//! file was compiled only where `cove-logging` exists (`macOS`, `Linux`,
//! `Windows`); the same `#[cfg]` keeps other targets from referencing it.

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
mod enabled {
    use std::collections::BTreeMap;

    use cove_logging::{Level, LogEvent, LogSystem, LogValue};

    const LABEL: &str = "com.cove.engine.plugin.host";
    const SOURCE: &str = "plugin.stderr";
    /// Swift flushed a partial line once the pending buffer grew past this.
    const MAXIMUM_PENDING_BYTES: usize = 32_768;

    pub struct PluginHostDiagnostics {
        pending: Vec<u8>,
        process_id: i32,
    }

    impl PluginHostDiagnostics {
        pub fn new() -> Self {
            PluginHostDiagnostics {
                pending: Vec::new(),
                process_id: 0,
            }
        }

        /// Emits whatever is still buffered, as the process's last partial line.
        pub fn finish(&mut self) {
            self.consume(&[], self.process_id, true);
        }

        pub fn consume(&mut self, data: &[u8], pid: i32, ending: bool) {
            self.process_id = pid;
            self.pending.extend_from_slice(data);
            let mut lines: Vec<Vec<u8>> = Vec::new();
            while let Some(end) = self.pending.iter().position(|byte| *byte == 10) {
                lines.push(self.pending[..end].to_vec());
                self.pending.drain(..=end);
            }
            if self.pending.len() > MAXIMUM_PENDING_BYTES || (ending && !self.pending.is_empty()) {
                lines.push(std::mem::take(&mut self.pending));
            }
            for line in lines {
                if line.is_empty() {
                    continue;
                }
                let mut metadata: BTreeMap<String, LogValue> = BTreeMap::new();
                metadata.insert("child_pid".to_string(), LogValue::String(pid.to_string()));
                metadata.insert("stream".to_string(), LogValue::String("stderr".to_string()));
                let message = String::from_utf8_lossy(&line).into_owned();
                let mut event = LogEvent::new(Level::Warning, message).with_metadata(metadata);
                event.source = SOURCE.to_string();
                LogSystem::logger(LABEL).log(&event);
            }
        }
    }

    impl Default for PluginHostDiagnostics {
        fn default() -> Self {
            Self::new()
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
pub use enabled::PluginHostDiagnostics;
