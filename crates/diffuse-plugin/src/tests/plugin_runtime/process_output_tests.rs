//! Ported from `Engine/Tests/PluginRuntimeTests/ProcessOutputTests.swift`.
//!
//! Environment-dependent: runs `/usr/bin/head -c 10485760 /dev/zero`, which exists
//! on macOS and Linux only. The Swift suite carried the same
//! `#if os(macOS) || os(Linux)` guard and no presence check, so a missing `head`
//! is a hard failure there and here.

#[cfg(any(target_os = "macos", target_os = "linux"))]
mod enabled {
    use std::sync::Arc;

    use cove_system::command::{ProcessBudget, ProcessCommand};
    use cove_system::session::ProcessSession;

    use crate::processes::entry::ProcessEntry;
    use crate::uuid::Uuid;

    // @Test("burst output is retained but each poll stays below the RPC frame budget")
    #[test]
    fn chunks_large_output_before_reporting_exit() {
        let mut command = ProcessCommand::new(
            std::path::PathBuf::from("/usr/bin/head"),
            std::env::temp_dir(),
        );
        command.arguments = vec![
            "-c".to_string(),
            "10485760".to_string(),
            "/dev/zero".to_string(),
        ];
        let mut budget = ProcessBudget::new();
        budget.output_bytes = 20_971_520;
        let session = ProcessSession::new(&command, budget.clone()).expect("spawns head");
        let entry = ProcessEntry::new(
            Arc::new(session),
            Uuid::new(),
            "fixture",
            budget.output_bytes,
        );
        std::thread::sleep(std::time::Duration::from_millis(200));
        let mut output: Vec<u8> = Vec::new();
        let mut polls = 0usize;
        let mut exit_status: Option<i32> = None;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while exit_status.is_none() && std::time::Instant::now() < deadline {
            let update = entry.poll();
            assert_eq!(update.failure, None);
            assert!(
                update.stdout.len() <= ProcessEntry::CHUNK_BYTES,
                "each poll must stay under the chunk bound"
            );
            output.extend_from_slice(update.stdout.as_slice());
            polls += 1;
            exit_status = update.exit_status;
            if exit_status.is_none() {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        assert_eq!(output.len(), 10_485_760);
        assert_eq!(exit_status, Some(0));
        assert!(polls >= 3, "output must be split across polls, got {polls}");
        assert!(output.iter().all(|byte| *byte == 0));
    }
}
