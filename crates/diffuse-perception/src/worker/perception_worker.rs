//! `PerceptionWorker.swift` — worker trait and default entry points.
//!
//! Swift's `async`/`Task.detached` becomes a scoped thread (MIGRATION.md §5.5):
//! the work still runs off the calling thread and the caller blocks on the result.

use std::path::{Path, PathBuf};

use diffuse_kernel::codable::new_uuid;

use crate::core::perception_contracts::{
    PerceptionModelManifest, PerceptionRequest, PerceptionResult,
};
use crate::gates::license_gate::LicenseGateDecision;

#[derive(Debug, thiserror::Error)]
pub enum PerceptionRuntimeError {
    #[error("Perception input file not found: {0}")]
    FileNotFound(String),
    #[error("Perception worker unavailable: {0}")]
    WorkerUnavailable(String),
    #[error("Perception inference failed: {0}")]
    InferenceFailed(String),
    #[error("Perception inference produced no observations")]
    NoObservations,
    #[error("Perception model denied by license gate: {0}")]
    LicenseDenied(LicenseGateDecision),
}

pub trait PerceptionWorker: Send + Sync {
    fn manifest(&self) -> PerceptionModelManifest;

    fn analyze_image(
        &self,
        url: &Path,
        request_id: &str,
        max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError>;

    /// Swift `analyzeImage(at:)` default.
    fn analyze_image_default(
        &self,
        url: &Path,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        self.analyze_image(url, &new_uuid(), 5)
    }

    /// Swift `analyzeImage(at:maxResults:)` default.
    fn analyze_image_with_max_results(
        &self,
        url: &Path,
        max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        self.analyze_image(url, &new_uuid(), max_results)
    }

    /// Runs inference on a background thread so callers avoid blocking.
    fn analyze_image_async(
        &self,
        url: &Path,
        request_id: &str,
        max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        std::thread::scope(|scope| {
            let handle = scope.spawn(|| self.analyze_image(url, request_id, max_results));
            match handle.join() {
                Ok(result) => result,
                Err(panic) => std::panic::resume_unwind(panic),
            }
        })
    }

    /// Swift `analyzeImageAsync(at:)` default: fresh request ID, 5 results.
    fn analyze_image_async_default(
        &self,
        url: &Path,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        self.analyze_image_async(url, &new_uuid(), 5)
    }

    /// Full-contract entry point via `PerceptionRequest`.
    fn handle(
        &self,
        request: &PerceptionRequest,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        let url: PathBuf = match request.input_uri.strip_prefix("file://") {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(&request.input_uri),
        };
        if !url.exists() {
            return Err(PerceptionRuntimeError::FileNotFound(
                url.display().to_string(),
            ));
        }
        self.analyze_image(&url, &request.request_id, request.max_results)
    }

    fn handle_async(
        &self,
        request: &PerceptionRequest,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        std::thread::scope(|scope| {
            let handle = scope.spawn(|| self.handle(request));
            match handle.join() {
                Ok(result) => result,
                Err(panic) => std::panic::resume_unwind(panic),
            }
        })
    }
}
