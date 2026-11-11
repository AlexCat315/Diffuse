//! `Editor/Sources/EditorCore/Tasks/Results.swift`.

use serde::Deserialize;

/// A project as its task plugin describes it: what can run, and sections of
/// named items such as products, targets and dependencies.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct TaskProjectDescription {
    pub name: String,
    /// Targets `run` accepts.
    pub runnables: Vec<String>,
    pub sections: Vec<TaskProjectSection>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct TaskProjectSection {
    pub title: String,
    pub items: Vec<TaskProjectItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct TaskProjectItem {
    pub name: String,
    pub detail: String,
}

/// A compiler or linker message a task plugin read from output.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct TaskProblem {
    /// As printed: absolute, or relative to the project folder.
    pub file: String,
    pub line: i64,
    pub column: i64,
    pub severity: TaskProblemSeverity,
    pub message: String,
}

impl TaskProblem {
    pub fn id(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}",
            self.file,
            self.line,
            self.column,
            self.severity.raw_value(),
            self.message
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskProblemSeverity {
    Error,
    Warning,
    Note,
}

impl TaskProblemSeverity {
    pub fn raw_value(self) -> &'static str {
        match self {
            TaskProblemSeverity::Error => "error",
            TaskProblemSeverity::Warning => "warning",
            TaskProblemSeverity::Note => "note",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct TaskTest {
    /// `Group.Subgroup/test`: everything before the slash groups the test.
    pub id: String,
    pub status: TaskTestStatus,
    /// The first issue a failing test recorded.
    #[serde(default)]
    pub message: Option<String>,
}

impl TaskTest {
    pub fn group(&self) -> &str {
        self.id
            .split_once('/')
            .map(|(group, _)| group)
            .unwrap_or(&self.id)
    }

    pub fn name(&self) -> &str {
        self.id
            .split_once('/')
            .map(|(_, name)| name)
            .unwrap_or(&self.id)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskTestStatus {
    NotRun,
    Running,
    Passed,
    Failed,
    Skipped,
}

impl TaskTestStatus {
    pub fn raw_value(self) -> &'static str {
        match self {
            TaskTestStatus::NotRun => "notRun",
            TaskTestStatus::Running => "running",
            TaskTestStatus::Passed => "passed",
            TaskTestStatus::Failed => "failed",
            TaskTestStatus::Skipped => "skipped",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskKind {
    Build,
    Test,
    Run,
    Clean,
    Resolve,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskRun {
    pub kind: TaskKind,
    /// What it ran for: a target for `run`, a test for `test`.
    pub subject: Option<String>,
    pub is_running: bool,
    pub status: Option<i32>,
    pub failure: Option<String>,
}

impl TaskRun {
    pub fn new(kind: TaskKind, subject: Option<String>) -> Self {
        TaskRun {
            kind,
            subject,
            is_running: true,
            status: None,
            failure: None,
        }
    }

    pub fn succeeded(&self) -> bool {
        !self.is_running && self.status == Some(0) && self.failure.is_none()
    }
}

/// The project's tasks as the editor shows them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TaskSnapshot {
    /// The contribution whose marker the project folder holds.
    pub title: Option<String>,
    pub description: Option<TaskProjectDescription>,
    pub run: Option<TaskRun>,
    pub problems: Vec<TaskProblem>,
    pub tests: Vec<TaskTest>,
}

impl TaskSnapshot {
    pub fn is_available(&self) -> bool {
        self.title.is_some()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TaskOutputEvent {
    Started(TaskRun),
    Output(Vec<u8>),
    Finished(TaskRun),
}

/// What a task plugin returns for every task but `describe`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct TaskReport {
    pub exit: i32,
    pub problems: Vec<TaskProblem>,
    #[serde(default)]
    pub tests: Option<Vec<TaskTest>>,
}
