//! Translation of
//! `Editor/Sources/EditorCore/Application/Plugins/ServiceJobs.swift`.
//!
//! Native and cross-plugin work is asynchronous. Every job belongs to its
//! calling plugin. Rust has no async runtime (§5.5), so a job runs on its own
//! thread and reports its result through a shared slot; `cancel` sets the
//! cancellation flag the work observes instead of aborting the thread.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::ThreadId;
use std::time::Duration;

use diffuse_plugin::PluginError;
use diffuse_plugin::host::plugin_host_process_client::PluginHostClientError;
use serde_json::{Value, json};

/// Cooperative cancellation handed to every job. Swift's work checked
/// `Task.checkCancellation`; the Rust closure calls `check` at the same points.
#[derive(Clone, Default)]
pub struct PluginServiceJobCancellation(Arc<AtomicBool>);

impl PluginServiceJobCancellation {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    pub fn check(&self) -> Result<(), PluginError> {
        if self.is_cancelled() {
            return Err(PluginHostClientError::RequestRejected(
                "The plugin service job was cancelled.".into(),
            )
            .into());
        }
        Ok(())
    }
}

struct Job {
    owner: String,
    cancellation: PluginServiceJobCancellation,
    result: Arc<Mutex<Option<Result<Vec<u8>, PluginError>>>>,
}

/// Jobs, per-owner cleanup and the service-call waiter.
#[derive(Default)]
pub struct PluginServiceJobs {
    jobs: Mutex<BTreeMap<String, Job>>,
    cleanups: Mutex<BTreeMap<String, Vec<Arc<dyn Fn() + Send + Sync>>>>,
}

impl PluginServiceJobs {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn own(&self, owner: &str, cleanup: impl Fn() + Send + Sync + 'static) {
        self.cleanups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(owner.to_string())
            .or_default()
            .push(Arc::new(cleanup));
    }

    /// Starts `work` on its own thread. The returned id polls the result.
    pub fn start(
        &self,
        owner: &str,
        work: impl FnOnce(&PluginServiceJobCancellation) -> Result<Vec<u8>, PluginError>
        + Send
        + 'static,
    ) -> Result<String, PluginError> {
        let id = diffuse_kernel::codable::new_uuid();
        let cancellation = PluginServiceJobCancellation::new();
        let result: Arc<Mutex<Option<Result<Vec<u8>, PluginError>>>> = Arc::new(Mutex::new(None));
        {
            let mut jobs = self
                .jobs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if jobs.len() >= 256 {
                return Err(PluginHostClientError::RequestRejected(
                    "The plugin that provides this is no longer enabled.".into(),
                )
                .into());
            }
            jobs.insert(
                id.clone(),
                Job {
                    owner: owner.to_string(),
                    cancellation: cancellation.clone(),
                    result: result.clone(),
                },
            );
        }
        let sink = result;
        let token = cancellation;
        std::thread::Builder::new()
            .name("com.cove.editor.plugin-service-job".to_string())
            .spawn(move || {
                let outcome = work(&token);
                *sink
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(outcome);
            })
            .map_err(|error| PluginError::Io(error))?;
        Ok(id)
    }

    /// `{"status":"running"}` until the job finishes, then a completed value or
    /// the failure message.
    pub fn poll(&self, id: &str, owner: &str) -> Result<Vec<u8>, PluginError> {
        let mut jobs = self
            .jobs
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let job = jobs
            .get(id)
            .filter(|job| job.owner == owner)
            .ok_or_else(|| {
                PluginError::from(PluginHostClientError::RequestRejected(
                    "The plugin that provides this is no longer enabled.".into(),
                ))
            })?;
        let outcome = job
            .result
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        let Some(outcome) = outcome else {
            return Ok(br#"{"status":"running"}"#.to_vec());
        };
        job.cancellation.cancel();
        jobs.remove(id);
        drop(jobs);
        match outcome {
            Ok(value) => {
                let parsed: Value = serde_json::from_slice(&value)?;
                Ok(serde_json::to_vec(
                    &json!({ "status": "completed", "value": parsed }),
                )?)
            }
            Err(error) => Ok(serde_json::to_vec(
                &json!({ "status": "failed", "error": error.to_string() }),
            )?),
        }
    }

    pub fn cancel(&self, id: &str, owner: &str) {
        let job = {
            let mut jobs = self
                .jobs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            match jobs.get(id) {
                Some(job) if job.owner == owner => jobs.remove(id),
                _ => None,
            }
        };
        if let Some(job) = job {
            job.cancellation.cancel();
        }
    }

    pub fn cancel_owner(&self, owner: &str) {
        let cancelled: Vec<Job> = {
            let mut jobs = self
                .jobs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let ids: Vec<String> = jobs
                .iter()
                .filter(|(_, job)| job.owner == owner)
                .map(|(id, _)| id.clone())
                .collect();
            ids.into_iter().filter_map(|id| jobs.remove(&id)).collect()
        };
        for job in cancelled {
            job.cancellation.cancel();
        }
        let cleanups = self
            .cleanups
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(owner)
            .unwrap_or_default();
        for cleanup in cleanups {
            cleanup();
        }
    }

    pub fn cancel_all(&self) {
        let owners: Vec<String> = {
            let jobs = self
                .jobs
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let cleanups = self
                .cleanups
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            jobs.values()
                .map(|job| job.owner.clone())
                .chain(cleanups.keys().cloned())
                .collect::<std::collections::BTreeSet<_>>()
                .into_iter()
                .collect()
        };
        for owner in owners {
            self.cancel_owner(&owner);
        }
    }
}

/// Only the pipe reader blocks; work always runs on the application thread.
pub struct PluginHostCallWaiter {
    result: Mutex<Option<Result<Vec<u8>, PluginError>>>,
    condvar: Condvar,
    creator: ThreadId,
}

impl PluginHostCallWaiter {
    pub fn new() -> Self {
        PluginHostCallWaiter {
            result: Mutex::new(None),
            condvar: Condvar::new(),
            creator: std::thread::current().id(),
        }
    }

    pub fn complete(&self, value: Result<Vec<u8>, PluginError>) {
        *self
            .result
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(value);
        self.condvar.notify_all();
    }

    /// Rejects a call that would wait on the thread that created the waiter,
    /// matching Swift's main-thread guard.
    pub fn wait(&self) -> Result<Vec<u8>, PluginError> {
        if std::thread::current().id() == self.creator {
            return Err(PluginHostClientError::RequestRejected(
                "Plugin host callback reached the UI thread".into(),
            )
            .into());
        }
        let guard = self
            .result
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (mut guard, timeout) = self
            .condvar
            .wait_timeout_while(guard, Duration::from_secs(4), |value| value.is_none())
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if timeout.timed_out() {
            return Err(PluginHostClientError::RequestRejected(
                "Plugin host service deadline exceeded".into(),
            )
            .into());
        }
        let Some(result) = guard.take() else {
            return Err(PluginHostClientError::RequestRejected(
                "Plugin host service returned no result".into(),
            )
            .into());
        };
        result
    }
}

impl Default for PluginHostCallWaiter {
    fn default() -> Self {
        Self::new()
    }
}
