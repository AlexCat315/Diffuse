//! Translation of `Editor/Sources/EditorCore/Application/Plugins/Monitor.swift`.
//!
//! Cross-platform monitor for changes to enabled plugin packages.
//!
//! Polling is intentional, mirroring `ScriptDirectoryMonitor`: builds replace
//! package files atomically, which invalidates file-descriptor watchers, and a
//! snapshot behaves consistently on macOS, Linux, and Windows. Watching is
//! opt-in (`--watch-plugins` / `COVE_WATCH_PLUGINS`) and never authorizes a
//! changed package on its own.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, UNIX_EPOCH};

use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;
use diffuse_plugin::contract::resources::PluginResource;

#[derive(Clone, Debug, PartialEq)]
struct FileSnapshot {
    size: u64,
    modification_time: f64,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Entry {
    files: BTreeMap<String, FileSnapshot>,
}

#[derive(Default)]
struct MonitorState {
    packages: BTreeMap<String, PathBuf>,
    previous_snapshot: BTreeMap<String, Entry>,
}

/// Polls the watched packages on a dedicated thread. `on_change` receives the
/// changed plugin ids, at most once per observed change until the files change
/// again. The callback runs on the monitor thread, matching Swift's main-queue
/// hop only in ordering, not in thread; callers marshal if they need the UI
/// thread.
pub struct PluginPackageMonitor {
    state: Arc<(Mutex<MonitorState>, Condvar)>,
    running: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl PluginPackageMonitor {
    pub fn new() -> Self {
        PluginPackageMonitor {
            state: Arc::new((Mutex::new(MonitorState::default()), Condvar::new())),
            running: Arc::new(AtomicBool::new(false)),
            thread: Mutex::new(None),
        }
    }

    /// Starts polling. Only the first call takes effect until `stop`.
    pub fn start(&mut self, interval: Duration, on_change: impl Fn(Vec<String>) + Send + 'static) {
        if self.running.swap(true, Ordering::SeqCst) {
            return;
        }
        let bounded = if interval.as_secs_f64().is_finite() {
            interval.clamp(Duration::from_millis(250), Duration::from_secs(3_600))
        } else {
            Duration::from_secs(1)
        };
        let state = self.state.clone();
        let running = self.running.clone();
        {
            let (lock, _) = &*state;
            let mut guard = lock
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            guard.previous_snapshot = Self::snapshot(&guard.packages);
        }
        let handle = std::thread::Builder::new()
            .name("com.cove.editor.plugin-package-monitor".to_string())
            .spawn(move || {
                let (lock, condvar) = &*state;
                loop {
                    let guard = lock
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    let (mut guard, _) = condvar
                        .wait_timeout(guard, bounded)
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if !running.load(Ordering::SeqCst) {
                        break;
                    }
                    let next = Self::snapshot(&guard.packages);
                    if next == guard.previous_snapshot {
                        continue;
                    }
                    let mut changed: Vec<String> = next
                        .keys()
                        .chain(guard.previous_snapshot.keys())
                        .filter(|id| next.get(*id) != guard.previous_snapshot.get(*id))
                        .cloned()
                        .collect();
                    changed.sort();
                    changed.dedup();
                    guard.previous_snapshot = next;
                    drop(guard);
                    if !changed.is_empty() {
                        on_change(changed);
                    }
                }
            })
            .ok();
        *self
            .thread
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handle;
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
        let (_, condvar) = &*self.state;
        condvar.notify_all();
        let handle = self
            .thread
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }

    /// Replaces the watched package set and rebases the snapshot, so binding
    /// changes themselves are never reported as file changes.
    pub fn set_packages(&self, packages: BTreeMap<String, PathBuf>) {
        let (lock, _) = &*self.state;
        let mut guard = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.packages = packages;
        guard.previous_snapshot = Self::snapshot(&guard.packages);
    }

    fn snapshot(packages: &BTreeMap<String, PathBuf>) -> BTreeMap<String, Entry> {
        let mut result = BTreeMap::new();
        for (plugin_id, url) in packages {
            let mut files: BTreeMap<String, FileSnapshot> = BTreeMap::new();
            let resources: Vec<String> = std::fs::read(url.join("plugin.json"))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<CovePluginManifest>(&bytes).ok())
                .map(|manifest| {
                    manifest
                        .resources
                        .iter()
                        .map(|resource| resource.path.clone())
                        .filter(|path| PluginResource::is_valid_path(path))
                        .collect()
                })
                .unwrap_or_default();
            let names = ["plugin.json", "capabilities.json", "plugin.js"];
            for name in names
                .iter()
                .copied()
                .chain(resources.iter().map(String::as_str))
            {
                let file_url = url.join(name);
                let Some(snapshot) = Self::file_snapshot(&file_url) else {
                    continue;
                };
                files.insert(name.to_string(), snapshot);
            }
            result.insert(plugin_id.clone(), Entry { files });
        }
        result
    }

    fn file_snapshot(path: &Path) -> Option<FileSnapshot> {
        let metadata = std::fs::metadata(path).ok()?;
        let modified = metadata.modified().ok()?;
        let modification_time = modified.duration_since(UNIX_EPOCH).ok()?.as_secs_f64();
        Some(FileSnapshot {
            size: metadata.len(),
            modification_time,
        })
    }
}

impl Default for PluginPackageMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for PluginPackageMonitor {
    fn drop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        let (_, condvar) = &*self.state;
        condvar.notify_all();
    }
}
