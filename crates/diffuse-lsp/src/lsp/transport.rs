//! `LanguageServerTransport` — the read side and write side of a server's pipes.
//!
//! Swift's transport carried an `AsyncThrowingStream<ProcessEvent, Error>` plus
//! `write`/`stop` closures. MIGRATION.md §5.5 forbids an async runtime, so the
//! event side becomes an iterator over the same events.

use std::sync::Arc;

use cove_system::command::ProcessEvent;
use cove_system::event_buffer::{Failure, ProcessFailure};
use cove_system::session::ProcessSession;

/// Stdin writer handed to the transport.
pub type Writer = Box<dyn Fn(&[u8]) -> Result<(), ProcessFailure> + Send + Sync>;

/// The transport a language-server client drives.
///
/// `events` yields process events until the stream ends; `write` sends stdin
/// bytes and `stop` terminates the process exactly once.
pub struct LanguageServerTransport {
    events: Box<dyn Iterator<Item = Result<ProcessEvent, Failure>> + Send>,
    write: Writer,
    stop: Box<dyn Fn() + Send + Sync>,
}

impl LanguageServerTransport {
    pub fn new(
        events: Box<dyn Iterator<Item = Result<ProcessEvent, Failure>> + Send>,
        write: impl Fn(&[u8]) -> Result<(), ProcessFailure> + Send + Sync + 'static,
        stop: impl Fn() + Send + Sync + 'static,
    ) -> Self {
        LanguageServerTransport { events, write: Box::new(write), stop: Box::new(stop) }
    }

    /// Builds a transport over a live Cove process session.
    pub fn from_session(session: Arc<ProcessSession>) -> Self {
        let events = Box::new(session.events());
        let write_session = session.clone();
        let stop_session = session.clone();
        LanguageServerTransport {
            events,
            write: Box::new(move |data| write_session.write(data)),
            stop: Box::new(move || stop_session.cancel()),
        }
    }

    /// Reads the next event; `None` once the stream has closed.
    pub fn next_event(&mut self) -> Option<Result<ProcessEvent, Failure>> {
        self.events.next()
    }

    pub fn write(&self, data: &[u8]) -> Result<(), ProcessFailure> {
        (self.write)(data)
    }

    pub fn stop(&self) {
        (self.stop)();
    }
}

/// A cheap, cloneable handle for callers that must close the transport from a
/// different thread.
pub type SharedTransport = Arc<LanguageServerTransport>;
