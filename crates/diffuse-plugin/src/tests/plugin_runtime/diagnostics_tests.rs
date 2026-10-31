//! Ported from `Engine/Tests/PluginRuntimeTests/DiagnosticsTests.swift`.

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
mod enabled {
    use std::sync::{Arc, Mutex};
    use std::time::{SystemTime, UNIX_EPOCH};

    use cove_logging::{LogQuery, LogRecord, LogSystem, LogValue};

    use crate::host::diagnostics::PluginHostDiagnostics;

    struct DiagnosticRecords {
        records: Mutex<Vec<LogRecord>>,
    }

    impl DiagnosticRecords {
        fn new() -> Self {
            DiagnosticRecords {
                records: Mutex::new(Vec::new()),
            }
        }

        fn append(&self, record: &LogRecord) {
            self.records
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .push(record.clone());
        }

        fn values(&self) -> Vec<LogRecord> {
            self.records
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .clone()
        }
    }

    // Swift: `@Test func pluginDiagnosticsFrameFragmentedChunksAndKeepTheFinalPartialLine()`
    #[test]
    fn plugin_diagnostics_frame_fragmented_chunks_and_keep_the_final_partial_line() {
        // `UUID().uuidString` per run, so a concurrent test cannot observe ours.
        let marker = format!(
            "{:X}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0)
        );
        let captured = Arc::new(DiagnosticRecords::new());
        let sink = captured.clone();
        let query = LogQuery {
            text: Some(marker.clone()),
            ..LogQuery::default()
        };
        let observation = LogSystem::observe(
            query,
            false,
            Arc::new(move |record: &LogRecord| sink.append(record)),
        );

        let mut diagnostics = PluginHostDiagnostics::new();
        let filler = "x".repeat(200);
        let mut lines: Vec<String> = (0..500)
            .map(|index| format!("{marker} {index} {filler}"))
            .collect();
        lines.push(format!("{marker} final"));
        let data = lines.join("\n").into_bytes();
        let mut offset = 0usize;
        while offset < data.len() {
            let end = usize::min(offset + 137, data.len());
            diagnostics.consume(&data[offset..end], 42, false);
            offset = end;
        }
        diagnostics.finish();
        LogSystem::flush();
        observation.cancel();

        let values = captured.values();
        assert_eq!(values.len(), 501);
        assert_eq!(
            values.last().map(|record| record.message.clone()),
            Some(format!("{marker} final"))
        );
        assert!(values.iter().all(|record| {
            record.metadata.get("child_pid") == Some(&LogValue::String("42".to_string()))
        }));
    }
}
