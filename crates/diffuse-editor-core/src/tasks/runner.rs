//! Translation of `Editor/Sources/EditorCore/Tasks/Runner.swift`.
//!
//! The project's build, test and run tasks. The plugin that contributes tasks
//! for this kind of project decides each command and reads its output; this
//! runs one task at a time through the plugin's process permission, shows
//! output as it arrives and publishes what the plugin read.
//!
//! Swift's `Task {}` becomes a thread plus an `AtomicBool` cancellation token
//! (MIGRATION.md §5.5); the language-service hook runs on the workspace's own
//! thread and publishes through the same mutex.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cove_system::paths::PathIdentity;

use crate::contributions::host::{StepError, StepPlugin, StepPlugins};
use crate::contributions::steps::StepOutcome;
use crate::scripting::assets::script_workspace_model::{
    ScriptWorkspaceModel, ScriptWorkspaceSnapshot,
};
use crate::scripting::rust_analyzer::language::script_language_models::ScriptLanguageServiceState;
use crate::tasks::catalog::TaskProvider;
use crate::tasks::results::{
    TaskKind, TaskOutputEvent, TaskProblem, TaskProjectDescription, TaskReport, TaskRun,
    TaskSnapshot, TaskTest, TaskTestStatus,
};

/// Where the tests come from: the language service's index, so they are known
/// without building. Set by the application.
pub type TaskTestSource = Arc<dyn Fn() -> Result<Vec<String>, String> + Send + Sync>;

/// The language service's state as last seen: when it is ready, whether it is
/// indexing and the saved revision of every document.
#[derive(Clone, Debug, PartialEq, Eq)]
struct LanguageKey {
    is_ready: bool,
    is_indexing: bool,
    saved: Vec<u64>,
}

struct TasksState {
    snapshot: TaskSnapshot,
    test_source: Option<TaskTestSource>,
    language_observation: Option<u64>,
    language_key: Option<LanguageKey>,
    runner: Option<Arc<AtomicBool>>,
    test_refresh: Option<Arc<AtomicBool>>,
}

/// Observer registry shared with the language workspace; the token is the one
/// `ScriptWorkspaceModel::register_observer` hands out.
type ObserverMap = BTreeMap<u64, Arc<dyn Fn() + Send + Sync>>;
/// Streams a task's raw output to the terminal view.
pub type TaskOutputHandler = Arc<dyn Fn(TaskOutputEvent) + Send + Sync>;

pub struct EditorTasks {
    root: PathBuf,
    plugins: StepPlugins,
    state: Mutex<TasksState>,
    observers: Mutex<ObserverMap>,
    next_observer: AtomicU64,
    /// Each task's start, its raw output (terminal colours included) and its
    /// end, for the view that shows it.
    on_output: Mutex<Option<TaskOutputHandler>>,
}

impl EditorTasks {
    pub fn new(root: &Path, plugins: StepPlugins) -> Self {
        let root = PathIdentity::canonical_url(root);
        let providers = plugins.runtime.task_providers();
        let snapshot = TaskSnapshot {
            title: TaskProvider::provider_for(&root, &providers)
                .map(|provider| provider.contribution.title.clone()),
            ..TaskSnapshot::default()
        };
        EditorTasks {
            root,
            plugins,
            state: Mutex::new(TasksState {
                snapshot,
                test_source: None,
                language_observation: None,
                language_key: None,
                runner: None,
                test_refresh: None,
            }),
            observers: Mutex::new(BTreeMap::new()),
            next_observer: AtomicU64::new(0),
            on_output: Mutex::new(None),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, TasksState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn snapshot(&self) -> TaskSnapshot {
        self.lock().snapshot.clone()
    }

    pub fn set_on_output(&self, handler: Option<Arc<dyn Fn(TaskOutputEvent) + Send + Sync>>) {
        *self
            .on_output
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handler;
    }

    pub fn set_test_source(&self, source: Option<TaskTestSource>) {
        self.lock().test_source = source;
    }

    // MARK: Project

    /// Finds the provider again and re-reads the project's description.
    pub fn refresh(&self) {
        let providers = self.plugins.runtime.task_providers();
        let provider = TaskProvider::provider_for(&self.root, &providers).cloned();
        self.publish(|snapshot| {
            snapshot.title = provider
                .as_ref()
                .map(|provider| provider.contribution.title.clone());
            if provider.is_none() {
                snapshot.description = None;
            }
        });
        let Some(provider) = provider else {
            return;
        };
        let Ok(plugin) = self.plugins.plugin(&provider.step, &self.root) else {
            return;
        };
        let Ok(StepOutcome::Result(data)) = plugin.perform(
            &serde_json::json!({ "op": "describe" }),
            None,
            StepPlugin::WINDOW,
            None,
            None,
        ) else {
            return;
        };
        let Ok(description) = serde_json::from_slice::<TaskProjectDescription>(&data) else {
            return;
        };
        self.publish(|snapshot| snapshot.description = Some(description));
    }

    // MARK: Tests

    /// Lists the tests again whenever the language service settles: once it is
    /// ready, when indexing ends and after a file is saved.
    pub fn follow(self: &Arc<Self>, language: &Arc<ScriptWorkspaceModel>) {
        let tasks = Arc::downgrade(self);
        let language_weak = Arc::downgrade(language);
        let handler: Arc<dyn Fn() + Send + Sync> = Arc::new(move || {
            let (Some(tasks), Some(language)) = (tasks.upgrade(), language_weak.upgrade()) else {
                return;
            };
            tasks.language_changed(&language.snapshot());
        });
        let token = language.register_observer(handler);
        self.lock().language_observation = Some(token);
    }

    fn language_changed(self: &Arc<Self>, language: &ScriptWorkspaceSnapshot) {
        let key = LanguageKey {
            is_ready: language.language_service_state == ScriptLanguageServiceState::Ready,
            is_indexing: language
                .language_service_details
                .as_ref()
                .and_then(|details| details.indexing.as_ref())
                .is_some(),
            saved: language
                .documents
                .iter()
                .map(|document| document.saved_revision)
                .collect(),
        };
        {
            let mut state = self.lock();
            if state.language_key.as_ref() == Some(&key) {
                return;
            }
            state.language_key = Some(key.clone());
        }
        if key.is_ready && !key.is_indexing {
            self.schedule_test_refresh();
        }
    }

    fn schedule_test_refresh(self: &Arc<Self>) {
        if let Some(cancel) = self.lock().test_refresh.take() {
            cancel.store(true, Ordering::SeqCst);
        }
        let cancel = Arc::new(AtomicBool::new(false));
        self.lock().test_refresh = Some(cancel.clone());
        let tasks = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("editor-task-test-refresh".to_string())
            .spawn(move || {
                // Swift's `try? await Task.sleep(for: .seconds(1))`.
                for _ in 0..100 {
                    if cancel.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                if cancel.load(Ordering::SeqCst) {
                    return;
                }
                if let Some(tasks) = tasks.upgrade() {
                    tasks.refresh_tests();
                }
            })
            .ok();
    }

    /// Asks the test source again, keeping each known test's last result.
    pub fn refresh_tests(&self) {
        if !self.snapshot().is_available() {
            return;
        }
        let Some(source) = self.lock().test_source.clone() else {
            return;
        };
        let Ok(identifiers) = source() else {
            return;
        };
        self.publish(|snapshot| {
            let mut previous: BTreeMap<String, TaskTest> = BTreeMap::new();
            for test in &snapshot.tests {
                previous
                    .entry(test.id.clone())
                    .or_insert_with(|| test.clone());
            }
            snapshot.tests = identifiers
                .iter()
                .map(|identifier| {
                    previous.get(identifier).cloned().unwrap_or(TaskTest {
                        id: identifier.clone(),
                        status: TaskTestStatus::NotRun,
                        message: None,
                    })
                })
                .collect();
        });
    }

    // MARK: Tasks

    // Entry points are called from UI actions on the main thread.
    pub fn build(self: &Arc<Self>) {
        self.begin(TaskKind::Build, None);
    }

    /// Runs every test, or the one named `id`.
    pub fn test(self: &Arc<Self>, id: Option<&str>) {
        self.begin(TaskKind::Test, id.map(str::to_string));
    }

    pub fn run(self: &Arc<Self>, target: &str) {
        self.begin(TaskKind::Run, Some(target.to_string()));
    }

    pub fn clean(self: &Arc<Self>) {
        self.begin(TaskKind::Clean, None);
    }

    pub fn resolve(self: &Arc<Self>) {
        self.begin(TaskKind::Resolve, None);
    }

    pub fn stop(&self) {
        let state = self.lock();
        if let Some(cancel) = state.runner.as_ref() {
            cancel.store(true, Ordering::SeqCst);
        }
    }

    fn begin(self: &Arc<Self>, kind: TaskKind, subject: Option<String>) {
        if self.snapshot().run.is_some_and(|run| run.is_running) {
            return;
        }
        let providers = self.plugins.runtime.task_providers();
        let Some(provider) = TaskProvider::provider_for(&self.root, &providers).cloned() else {
            return;
        };
        self.publish(|snapshot| {
            snapshot.run = Some(TaskRun::new(kind, subject.clone()));
            if kind != TaskKind::Run {
                snapshot.problems = Vec::new();
            }
            if kind == TaskKind::Test {
                for test in snapshot.tests.iter_mut() {
                    if subject.is_none() || Some(&test.id) == subject.as_ref() {
                        test.status = TaskTestStatus::Running;
                        test.message = None;
                    }
                }
            }
        });
        if let Some(run) = self.snapshot().run {
            self.emit_output(TaskOutputEvent::Started(run));
        }
        let known: Vec<String> = self
            .snapshot()
            .tests
            .iter()
            .map(|test| test.id.clone())
            .collect();
        let cancel = Arc::new(AtomicBool::new(false));
        self.lock().runner = Some(cancel.clone());
        let tasks = Arc::downgrade(self);
        let plugins = self.plugins.clone();
        let root = self.root.clone();
        std::thread::Builder::new()
            .name("editor-task-runner".to_string())
            .spawn(move || {
                let mut operation = serde_json::Map::new();
                operation.insert(
                    "op".to_string(),
                    serde_json::Value::String(task_kind_raw_value(kind).to_string()),
                );
                match kind {
                    TaskKind::Test => {
                        if let Some(subject) = &subject {
                            operation.insert(
                                "filter".to_string(),
                                serde_json::Value::String(subject.clone()),
                            );
                        }
                        operation.insert("known".to_string(), serde_json::json!(known));
                    }
                    TaskKind::Run => {
                        operation.insert(
                            "target".to_string(),
                            serde_json::Value::String(subject.clone().unwrap_or_default()),
                        );
                    }
                    _ => {}
                }
                let operation = serde_json::Value::Object(operation);
                let mut report: Option<TaskReport> = None;
                let mut failure: Option<String> = None;
                let buffer = TaskOutputBuffer::new();
                let outcome = plugins.plugin(&provider.step, &root).and_then(|plugin| {
                    let emit = |chunk: &[u8]| {
                        buffer.append(chunk);
                        let bytes = buffer.take();
                        if !bytes.is_empty()
                            && let Some(tasks) = tasks.upgrade()
                        {
                            tasks.emit_output(TaskOutputEvent::Output(bytes));
                        }
                    };
                    plugin.perform(
                        &operation,
                        None,
                        StepPlugin::WINDOW,
                        Some(&emit),
                        Some(&cancel),
                    )
                });
                match outcome {
                    Ok(StepOutcome::Result(data)) => {
                        match serde_json::from_slice::<TaskReport>(&data) {
                            Ok(decoded) => report = Some(decoded),
                            Err(error) => failure = Some(error.to_string()),
                        }
                    }
                    Ok(StepOutcome::Output(_)) => {}
                    Err(StepError::Cancelled) => failure = Some("Stopped".to_string()),
                    Err(error) => {
                        failure = Some(if cancel.load(Ordering::SeqCst) {
                            "Stopped".to_string()
                        } else {
                            error.error_description()
                        });
                    }
                }
                if let Some(tasks) = tasks.upgrade() {
                    tasks.finish(kind, report, failure);
                }
            })
            .ok();
    }

    fn finish(
        self: &Arc<Self>,
        _kind: TaskKind,
        report: Option<TaskReport>,
        failure: Option<String>,
    ) {
        self.publish(|snapshot| {
            if let Some(run) = snapshot.run.as_mut() {
                run.is_running = false;
                run.status = report.as_ref().map(|report| report.exit);
                run.failure = failure.clone();
            }
            if let Some(report) = report.as_ref() {
                snapshot.problems = report.problems.clone();
                for result in report.tests.clone().unwrap_or_default() {
                    if let Some(index) = snapshot.tests.iter().position(|test| test.id == result.id)
                    {
                        snapshot.tests[index] = result;
                    } else {
                        snapshot.tests.push(result);
                    }
                }
            }
            // A test the output never reported on did not run to an answer.
            for test in snapshot
                .tests
                .iter_mut()
                .filter(|test| test.status == TaskTestStatus::Running)
            {
                test.status = TaskTestStatus::NotRun;
            }
        });
        if let Some(run) = self.snapshot().run {
            self.emit_output(TaskOutputEvent::Finished(run));
        }
        self.lock().runner = None;
        self.schedule_test_refresh();
    }

    /// Where a problem's file is: absolute, or relative to the project folder.
    pub fn url_of(&self, problem: &TaskProblem) -> PathBuf {
        if problem.file.starts_with('/') {
            PathBuf::from(&problem.file)
        } else {
            self.root.join(&problem.file)
        }
    }

    fn publish(&self, change: impl FnOnce(&mut TaskSnapshot)) {
        let changed = {
            let mut state = self.lock();
            let mut next = state.snapshot.clone();
            change(&mut next);
            if next == state.snapshot {
                false
            } else {
                state.snapshot = next;
                true
            }
        };
        if changed {
            let handlers: Vec<Arc<dyn Fn() + Send + Sync>> = self
                .observers
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .values()
                .cloned()
                .collect();
            for handler in handlers {
                handler();
            }
        }
    }

    fn emit_output(&self, event: TaskOutputEvent) {
        if let Some(handler) = self
            .on_output
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
        {
            handler(event);
        }
    }

    pub fn register_observer(&self, handler: Arc<dyn Fn() + Send + Sync>) -> u64 {
        let token = self.next_observer.fetch_add(1, Ordering::SeqCst);
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(token, handler);
        token
    }

    pub fn unregister_observer(&self, token: u64) {
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&token);
    }
}

/// Swift's `TaskKind.rawValue`.
fn task_kind_raw_value(kind: TaskKind) -> &'static str {
    match kind {
        TaskKind::Build => "build",
        TaskKind::Test => "test",
        TaskKind::Run => "run",
        TaskKind::Clean => "clean",
        TaskKind::Resolve => "resolve",
    }
}

/// Output chunks arrive off the main thread; each hop takes everything
/// gathered so far, so bytes keep their order whichever hop runs first.
struct TaskOutputBuffer {
    pending: Mutex<Vec<u8>>,
}

impl TaskOutputBuffer {
    fn new() -> Self {
        TaskOutputBuffer {
            pending: Mutex::new(Vec::new()),
        }
    }

    fn append(&self, chunk: &[u8]) {
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .extend_from_slice(chunk);
    }

    fn take(&self) -> Vec<u8> {
        std::mem::take(
            &mut *self
                .pending
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        )
    }
}
