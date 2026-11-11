//! `Editor/Sources/EditorCore/AI/Chat/EditorAgentTaskService.swift` — a
//! UI-independent task lifecycle shared by the thread, review and journal.

use std::collections::BTreeSet;
use std::thread::JoinHandle;

use diffuse_ai::planning::proposal::Proposal;
use diffuse_plugin::Uuid;

use crate::state::workspace::content::EditorContent;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorAgentTaskPhase {
    Planning,
    AwaitingReview,
    Applied,
    Completed,
    Discarded,
    Failed,
    Cancelled,
    Conflict,
}

impl EditorAgentTaskPhase {
    /// The Swift raw value of the phase.
    pub fn raw_value(self) -> &'static str {
        match self {
            EditorAgentTaskPhase::Planning => "planning",
            EditorAgentTaskPhase::AwaitingReview => "awaitingReview",
            EditorAgentTaskPhase::Applied => "applied",
            EditorAgentTaskPhase::Completed => "completed",
            EditorAgentTaskPhase::Discarded => "discarded",
            EditorAgentTaskPhase::Failed => "failed",
            EditorAgentTaskPhase::Cancelled => "cancelled",
            EditorAgentTaskPhase::Conflict => "conflict",
        }
    }

    pub fn is_terminal(self) -> bool {
        !matches!(
            self,
            EditorAgentTaskPhase::Planning | EditorAgentTaskPhase::AwaitingReview
        )
    }

    pub fn title(self) -> &'static str {
        match self {
            EditorAgentTaskPhase::Planning => "Planning",
            EditorAgentTaskPhase::AwaitingReview => "Awaiting Review",
            EditorAgentTaskPhase::Applied => "Applied",
            EditorAgentTaskPhase::Completed => "Completed",
            EditorAgentTaskPhase::Discarded => "Discarded",
            EditorAgentTaskPhase::Failed => "Failed",
            EditorAgentTaskPhase::Cancelled => "Cancelled",
            EditorAgentTaskPhase::Conflict => "Scene Changed",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorAgentTaskTarget {
    pub document_id: Uuid,
    pub scene_revision: u64,
    pub content: EditorContent,
    pub selected_entity_ids: BTreeSet<u64>,
    pub primary_entity_id: Option<u64>,
}

impl EditorAgentTaskTarget {
    pub fn new(
        document_id: Uuid,
        scene_revision: u64,
        content: EditorContent,
        selected_entity_ids: BTreeSet<u64>,
        primary_entity_id: Option<u64>,
    ) -> Self {
        EditorAgentTaskTarget {
            document_id,
            scene_revision,
            content,
            selected_entity_ids,
            primary_entity_id,
        }
    }

    pub fn matches(&self, document_id: &Uuid, scene_revision: u64) -> bool {
        &self.document_id == document_id && self.scene_revision == scene_revision
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct EditorAgentTask {
    pub id: Uuid,
    pub prompt: String,
    pub target: EditorAgentTaskTarget,
    pub phase: EditorAgentTaskPhase,
    pub summary: String,
}

impl EditorAgentTask {
    pub fn new(id: Uuid, prompt: impl Into<String>, target: EditorAgentTaskTarget) -> Self {
        EditorAgentTask {
            id,
            prompt: prompt.into(),
            target,
            phase: EditorAgentTaskPhase::Planning,
            summary: String::new(),
        }
    }

    /// Swift's `id: UUID = UUID()` default.
    pub fn with_default_id(prompt: impl Into<String>, target: EditorAgentTaskTarget) -> Self {
        Self::new(Uuid::new(), prompt, target)
    }
}

/// The lifecycle the thread, review and journal all read.
pub struct EditorAgentTaskService {
    tasks: Vec<EditorAgentTask>,
    active_task_id: Option<Uuid>,
}

impl EditorAgentTaskService {
    pub fn new() -> Self {
        EditorAgentTaskService {
            tasks: Vec::new(),
            active_task_id: None,
        }
    }

    pub fn tasks(&self) -> &[EditorAgentTask] {
        &self.tasks
    }

    pub fn active_task_id(&self) -> Option<&Uuid> {
        self.active_task_id.as_ref()
    }

    pub fn active_task(&self) -> Option<&EditorAgentTask> {
        let active_task_id = self.active_task_id.as_ref()?;
        self.tasks.iter().find(|task| &task.id == active_task_id)
    }

    pub fn begin(
        &mut self,
        prompt: impl Into<String>,
        target: EditorAgentTaskTarget,
    ) -> Option<EditorAgentTask> {
        if self.active_task_id.is_some() {
            return None;
        }
        let task = EditorAgentTask::with_default_id(prompt, target);
        self.tasks.insert(0, task.clone());
        self.tasks.truncate(40);
        self.active_task_id = Some(task.id.clone());
        Some(task)
    }

    pub fn transition(&mut self, phase: EditorAgentTaskPhase, summary: impl Into<String>) {
        let Some(active_task_id) = self.active_task_id.as_ref() else {
            return;
        };
        let Some(index) = self
            .tasks
            .iter()
            .position(|task| &task.id == active_task_id)
        else {
            return;
        };
        self.tasks[index].phase = phase;
        self.tasks[index].summary = summary.into();
        if phase.is_terminal() {
            self.active_task_id = None;
        }
    }
}

impl Default for EditorAgentTaskService {
    fn default() -> Self {
        Self::new()
    }
}

/// Transport handles stay separate from the task read model and preferences.
pub(crate) struct EditorAgentExecution {
    pub(crate) request_id: Option<Uuid>,
    pub(crate) request_task: Option<JoinHandle<()>>,
    pub(crate) proposal: Option<Proposal>,
    pub(crate) assistant_message_id: Option<String>,
    pub(crate) confirmation_target_entity_ids: BTreeSet<u64>,
}

impl EditorAgentExecution {
    pub(crate) fn new() -> Self {
        EditorAgentExecution {
            request_id: None,
            request_task: None,
            proposal: None,
            assistant_message_id: None,
            confirmation_target_entity_ids: BTreeSet::new(),
        }
    }
}
