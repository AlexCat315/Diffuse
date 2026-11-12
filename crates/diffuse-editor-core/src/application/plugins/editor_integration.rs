//! `Editor/Sources/EditorCore/Application/Plugins/EditorIntegration.swift`.
//!
//! Editor-facing state belongs to one plugin session, independently of its
//! process transport.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use super::installations::PluginInstallations;
use super::service_jobs::PluginServiceJobs;
use crate::application::editor_application::EditorApplication;
use crate::contributions::workbench::surfaces::WorkbenchSession;

pub type WorkspaceResolver = Rc<dyn Fn(&str) -> Result<Rc<EditorApplication>, String>>;
pub type PeerProvider = Rc<dyn Fn() -> Vec<Rc<EditorApplication>>>;

pub struct PluginEditorIntegration {
    pub workbench: WorkbenchSession,
    pub jobs: PluginServiceJobs,
    pub workspace_catalog: RefCell<BTreeMap<String, String>>,
    pub workspace_resolver: RefCell<Option<WorkspaceResolver>>,
    pub peers: RefCell<Option<PeerProvider>>,
    pub installations: RefCell<Option<PluginInstallations>>,
}

impl Default for PluginEditorIntegration {
    fn default() -> Self {
        Self::new()
    }
}

impl PluginEditorIntegration {
    pub fn new() -> Self {
        PluginEditorIntegration {
            workbench: WorkbenchSession::new(),
            jobs: PluginServiceJobs::new(),
            workspace_catalog: RefCell::new(BTreeMap::new()),
            workspace_resolver: RefCell::new(None),
            peers: RefCell::new(None),
            installations: RefCell::new(None),
        }
    }

    /// Stops queued service jobs and the contribution workbench.
    pub fn stop(&self) {
        self.jobs.cancel_all();
        self.workbench.stop();
    }
}
