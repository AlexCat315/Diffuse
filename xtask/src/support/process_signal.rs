//! Process termination shared by the tooling and the application bridge.

use std::process::{Child, Command};

/// Requests immediate termination of a running child.
pub struct ProcessSignal;

impl ProcessSignal {
    /// Kills a child that is still running; finished children are left alone.
    pub fn kill(child: &mut Child) {
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }
        let _ = child.kill();
    }

    /// Kills a process by identifier. Used where no `Child` handle is retained
    /// (the Swift original receives a `Foundation.Process`; the CLI keeps either
    /// a child handle or a bare pid).
    pub fn kill_pid(pid: u32) {
        #[cfg(unix)]
        {
            let _ = Command::new("kill")
                .args(["-KILL", &pid.to_string()])
                .status();
        }
        #[cfg(windows)]
        {
            let _ = Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/T", "/F"])
                .status();
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = pid;
        }
    }
}
