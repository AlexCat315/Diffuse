//! The renderer's log stream: `Logger.renderer` in Swift.
//!
//! `cove_logging` has no `Logger` facade type, so producers call the handler
//! directly (`LogSystem::logger(label).log(&event)`), mirroring the call shape
//! Cove's own crates use.

/// Swift's `Logger.renderer`: the `com.cove.engine.renderer` stream.
pub fn renderer() -> cove_logging::UnifiedLogHandler {
    cove_logging::LogSystem::logger("com.cove.engine.renderer")
}
