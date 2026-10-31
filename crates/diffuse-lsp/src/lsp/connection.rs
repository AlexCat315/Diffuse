//! `LSPConnection` — one server process plus the transport it speaks over.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use cove_system::command::ProcessBudget;
use cove_system::session::ProcessSession;

use crate::byte_stream::MAXIMUM_BODY_BYTES;
use crate::configuration::LanguageServerConfiguration;
use crate::lsp::error::LspClientError;
use crate::lsp::transport::LanguageServerTransport;

pub struct LspConnection {
    pub id: u64,
    transport: LanguageServerTransport,
    is_running: AtomicBool,
}

impl LspConnection {
    /// Swift's initializer: use the configuration's `connect` hook when present,
    /// otherwise spawn a `ProcessSession` with an unlimited lifetime and a body-
    /// sized output budget.
    pub fn new(configuration: &LanguageServerConfiguration) -> Result<Self, LspClientError> {
        let transport = match &configuration.connect {
            Some(connect) => connect(&configuration.command)
                .map_err(LspClientError::LaunchFailed)?,
            None => {
                let mut budget = ProcessBudget::new();
                budget.lifetime_milliseconds = None;
                budget.output_bytes = MAXIMUM_BODY_BYTES;
                let session = ProcessSession::new(&configuration.command, budget)
                    .map_err(|error| LspClientError::LaunchFailed(format!("{error:?}")))?;
                LanguageServerTransport::from_session(Arc::new(session))
            }
        };
        Ok(LspConnection {
            id: next_connection_id(),
            transport,
            is_running: AtomicBool::new(true),
        })
    }

    #[inline]
    pub fn is_running(&self) -> bool {
        self.is_running.load(Ordering::SeqCst)
    }

    pub fn transport(&self) -> &LanguageServerTransport {
        &self.transport
    }

    pub fn transport_mut(&mut self) -> &mut LanguageServerTransport {
        &mut self.transport
    }

    pub fn close(&self) {
        self.is_running.store(false, Ordering::SeqCst);
        self.transport.stop();
    }
}

impl Drop for LspConnection {
    fn drop(&mut self) {
        self.close();
    }
}

fn next_connection_id() -> u64 {
    use std::sync::atomic::AtomicU64;
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}
