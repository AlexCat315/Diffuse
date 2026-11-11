//! `Editor/Sources/EditorCore/Scripting/Assets/ScriptDirectoryMonitor.swift`.
//!
//! Cross-platform monitor for externally-created, renamed, edited, or deleted
//! top-level Swift files in a project's Scripts directory.
//!
//! Polling is intentional here: editor writes commonly replace a file
//! atomically, which invalidates file-descriptor watchers. A directory snapshot
//! also behaves consistently on macOS, Linux, and Windows.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, UNIX_EPOCH};

const POLL_INTERVAL: Duration = Duration::from_millis(650);

#[derive(Clone, Debug, PartialEq)]
struct Entry {
    size: u64,
    modification_time: f64,
}

pub struct ScriptDirectoryMonitor {
    directory_url: PathBuf,
    handle: Mutex<Option<MonitorThread>>,
}

struct MonitorThread {
    stop: Arc<(Mutex<bool>, Condvar)>,
    join: Option<JoinHandle<()>>,
}

impl ScriptDirectoryMonitor {
    pub fn new(directory_url: PathBuf) -> Self {
        Self {
            directory_url,
            handle: Mutex::new(None),
        }
    }

    pub fn start(&self, on_change: Arc<dyn Fn() + Send + Sync>) {
        let mut handle = self.lock();
        if handle.is_some() {
            return;
        }
        let stop = Arc::new((Mutex::new(false), Condvar::new()));
        let directory = self.directory_url.clone();
        let thread_stop = Arc::clone(&stop);
        let join = std::thread::Builder::new()
            .name("script-directory-monitor".to_string())
            .spawn(move || {
                let mut previous = snapshot(&directory);
                loop {
                    let (lock, cvar) = &*thread_stop;
                    let guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                    let (guard, _) = cvar
                        .wait_timeout(guard, POLL_INTERVAL)
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    if *guard {
                        break;
                    }
                    drop(guard);
                    let next = snapshot(&directory);
                    if next != previous {
                        previous = next;
                        on_change();
                    }
                }
            })
            .expect("script directory monitor thread");
        *handle = Some(MonitorThread {
            stop,
            join: Some(join),
        });
    }

    pub fn stop(&self) {
        let handle = self.lock().take();
        if let Some(handle) = handle {
            let (lock, cvar) = &*handle.stop;
            *lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = true;
            cvar.notify_all();
            // The timer thread exits on its next poll; the handle is detached
            // so a callback running on that thread can stop the monitor.
            drop(handle.join);
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<MonitorThread>> {
        self.handle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl Drop for ScriptDirectoryMonitor {
    fn drop(&mut self) {
        self.stop();
    }
}

fn snapshot(directory: &Path) -> BTreeMap<String, Entry> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return BTreeMap::new();
    };
    let mut result = BTreeMap::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("swift"))
        {
            continue;
        }
        let Some(name) = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
        else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let Ok(metadata) = std::fs::metadata(&path) else {
            continue;
        };
        if !metadata.is_file() {
            continue;
        }
        result.insert(
            name,
            Entry {
                size: metadata.len(),
                modification_time: metadata
                    .modified()
                    .map(|modified| match modified.duration_since(UNIX_EPOCH) {
                        Ok(duration) => duration.as_secs_f64(),
                        Err(error) => -error.duration().as_secs_f64(),
                    })
                    .unwrap_or(0.0),
            },
        );
    }
    result
}
