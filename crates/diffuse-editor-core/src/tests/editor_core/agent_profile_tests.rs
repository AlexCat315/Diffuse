//! `Editor/Tests/EditorCoreTests/AgentProfileTests.swift`.
//!
//! How a contributed agent narrows tools and context without ever widening
//! them, how its harness is mounted, and how the chosen agent survives a
//! settings round trip.
//!
//! Difference from Swift: `EditorApplication(projectDirectory:seedPreviewScene:
//! trustedPluginHostExecutableURL:)` is `with_options` and returns
//! `Rc<EditorApplication>`; the Swift `AgentContribution` convenience initialiser
//! is a struct literal here, and agents are installed into the plugin session's
//! `agents` catalog rather than a `pluginSession.agents` property.

use std::path::PathBuf;
use std::rc::Rc;

use diffuse_ai::session::session_workflow_scope::{SessionAgentContext, SessionContextSource};
use diffuse_plugin::contribution::ai::agent::AgentContribution;

use crate::ai::chat::editor_ai_settings::EditorAISettings;
use crate::application::ai::harnesses::AgentHarnessError;
use crate::application::editor_application::{EditorApplication, EditorApplicationOptions};
use crate::ai::chat::editor_agent_task_service::EditorAgentTaskTarget;
use crate::contributions::agents::{AgentCatalog, AgentDescriptor};
use crate::state::editor_reducer::EditorAction;
use crate::state::workspace::content::EditorContent;

fn temporary_project(label: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "cove-agent-profile-{}-{label}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&directory).expect("create temporary project");
    directory
}

fn launch(project: &PathBuf) -> Rc<EditorApplication> {
    EditorApplication::with_options(
        project.to_string_lossy().into_owned(),
        EditorApplicationOptions {
            seed_preview_scene: false,
            ..EditorApplicationOptions::default()
        },
    )
    .expect("launch editor")
}

fn agent_descriptor(
    id: &str,
    title: &str,
    instructions: Option<&str>,
    tools: Option<Vec<&str>>,
    context: Option<Vec<&str>>,
    harness: Option<&str>,
) -> AgentDescriptor {
    let mut contribution = AgentContribution::new(id, title);
    contribution.instructions = instructions.map(str::to_string);
    contribution.tools = tools.map(|tools| tools.into_iter().map(str::to_string).collect());
    contribution.context = context.map(|context| context.into_iter().map(str::to_string).collect());
    contribution.harness = harness.map(str::to_string);
    AgentDescriptor::new("fixture.agents", &contribution)
}

fn target(app: &EditorApplication) -> EditorAgentTaskTarget {
    EditorAgentTaskTarget {
        document_id: app.store.state().document.identity,
        scene_revision: app.store.scene_revision(),
        content: EditorContent::Scene,
        selected_entity_ids: Default::default(),
        primary_entity_id: None,
    }
}

#[test]
fn an_agent_narrows_tools_and_context_but_keeps_respond() {
    let project = temporary_project("narrow");
    let app = launch(&project);

    let open = app.make_agent_workflow_scope(&target(&app));
    assert_eq!(
        open.agent,
        SessionAgentContext::new(None, None, Vec::new())
    );
    assert_eq!(
        open.allowed_project_tool_names,
        Some(EditorContent::Scene.profile().project_tool_names())
    );

    app.plugin_session.state().agents = AgentCatalog::new(vec![
        agent_descriptor(
            "reviewer",
            "Reviewer",
            Some("Only review."),
            Some(vec!["read_file", "scene.set_name", "write_anything"]),
            Some(vec!["selection", "git-summary"]),
            None,
        ),
        agent_descriptor("builder", "Builder", None, None, None, None),
    ]);

    let narrowed = app.make_agent_workflow_scope(&target(&app));
    assert_eq!(
        narrowed.allowed_capability_ids,
        Some(["scene.set_name".to_string()].into_iter().collect())
    );
    assert_eq!(
        narrowed.allowed_project_tool_names,
        Some(["respond".to_string()].into_iter().collect())
    );
    assert_eq!(narrowed.agent.instructions.as_deref(), Some("Only review."));
    assert_eq!(
        narrowed.agent.sources,
        Some([SessionContextSource::Selection].into_iter().collect())
    );

    let mut settings = app.store.ai_settings();
    settings.agent_id = "builder".to_string();
    app.store.dispatch(EditorAction::SetAISettings(settings));
    assert_eq!(
        app.make_agent_workflow_scope(&target(&app))
            .agent
            .instructions,
        None
    );

    let mut settings = app.store.ai_settings();
    settings.agent_id = "removed".to_string();
    app.store.dispatch(EditorAction::SetAISettings(settings));
    // An unknown id falls back to the first enabled agent.
    assert_eq!(
        app.make_agent_workflow_scope(&target(&app))
            .agent
            .instructions
            .as_deref(),
        Some("Only review.")
    );

    app.shutdown();
    let _ = std::fs::remove_dir_all(&project);
}

#[test]
fn the_agents_harness_must_be_enabled() {
    let project = temporary_project("harness");
    let app = launch(&project);

    assert!(app.agent_harness().expect("no harness needed").is_none());
    app.plugin_session.state().agents = AgentCatalog::new(vec![agent_descriptor(
        "careful",
        "Careful",
        None,
        None,
        None,
        Some("careful"),
    )]);
    match app.agent_harness() {
        Err(AgentHarnessError::Unavailable(name)) => assert_eq!(name, "careful"),
        Ok(Some(_)) => panic!("expected an unavailable harness, got a mounted one"),
        Ok(None) => panic!("expected an unavailable harness, got the built-in loop"),
        Err(other) => panic!("expected an unavailable harness, got {other}"),
    }

    app.shutdown();
    let _ = std::fs::remove_dir_all(&project);
}

#[test]
fn agent_context_splits_host_sources_from_package_context() {
    let agent = agent_descriptor(
        "a",
        "A",
        None,
        None,
        Some(vec!["scene", "memory", "git-summary"]),
        None,
    );
    assert_eq!(
        agent.host_sources(),
        Some(
            [
                SessionContextSource::Scene,
                SessionContextSource::Memory
            ]
            .into_iter()
            .collect()
        )
    );
    assert_eq!(
        agent.package_contexts(),
        ["git-summary".to_string()].into_iter().collect()
    );

    let open = agent_descriptor("b", "B", None, None, None, None);
    assert_eq!(open.host_sources(), None);
    assert!(open.package_contexts().is_empty());
}

#[test]
fn package_context_is_cut_without_splitting_a_scalar() {
    assert_eq!(EditorApplication::prefix("short", 16), "short");
    assert_eq!(EditorApplication::prefix("aé", 2), "a");
    assert_eq!(EditorApplication::prefix("aéb", 3), "aé");
}

#[test]
fn settings_keep_the_chosen_agent() {
    let settings = EditorAISettings {
        provider_id: "anthropic".to_string(),
        model: "m".to_string(),
        agent_id: "reviewer".to_string(),
        ..EditorAISettings::default()
    };
    let encoded = serde_json::to_vec(&settings).expect("encode settings");
    let decoded: EditorAISettings = serde_json::from_slice(&encoded).expect("decode settings");
    assert_eq!(decoded, settings);

    let missing: EditorAISettings = serde_json::from_slice(br#"{"provider_id":"anthropic"}"#)
        .expect("decode partial settings");
    assert!(missing.agent_id.is_empty());
}
