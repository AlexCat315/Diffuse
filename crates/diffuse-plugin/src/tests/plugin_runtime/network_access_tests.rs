//! Ported from `Engine/Tests/PluginRuntimeTests/NetworkAccessTests.swift`.

use diffuse_capability::capability_registry::CapabilityRegistry;

use crate::contract::plugin_manifest::{PluginManifestValidationError, PluginManifestValidator};
use crate::contribution::ai::agent::{AgentContribution, AgentContributionPoint};

use crate::contribution::registry::ContributionPointRegistry;

fn manifest(host: &str) -> Vec<u8> {
    format!(
        r#"
        {{"id": "test.net", "version": 1, "name": "Net", "description": "fixture", "access": "read",
         "imports": ["cove:http/host"], "composable_host_capabilities": [],
         "host": {host}, "contributes": {{}}}}
        "#
    )
    .into_bytes()
}

fn decode(
    data: &[u8],
) -> Result<crate::contract::plugin_manifest::CovePluginManifest, PluginManifestValidationError> {
    PluginManifestValidator::decode_and_validate(
        data,
        &CapabilityRegistry::default_registry(),
        &ContributionPointRegistry::standard(),
    )
}

// @Test("a package must declare the hosts it may reach")
#[test]
fn http_permission_is_required_by_import() {
    let valid = decode(&manifest(
        r#"{"http": [{"id": "api", "hosts": ["api.example.com"]}]}"#,
    ))
    .expect("valid manifest");
    assert_eq!(valid.host.http.len(), 1);
    assert!(valid.host.http[0].allows("api.example.com"));
    assert!(!valid.host.http[0].allows("evil.example.com"));
}

// @Test("declaring network reach without the import, or the reverse, is rejected")
#[test]
fn http_permission_and_import_must_agree() {
    assert_eq!(
        decode(
            br#"
            {"id": "test.net", "version": 1, "name": "Net", "description": "fixture", "access": "read",
             "imports": ["cove:http/host"], "composable_host_capabilities": [],
             "host": {"http": []}, "contributes": {}}
            "#
        ),
        Err(PluginManifestValidationError::InvalidHostPermissions)
    );
    assert_eq!(
        decode(
            br#"
            {"id": "test.net", "version": 1, "name": "Net", "description": "fixture", "access": "read",
             "imports": [], "composable_host_capabilities": [],
             "host": {"http": [{"id": "api", "hosts": ["api.example.com"]}]}, "contributes": {}}
            "#
        ),
        Err(PluginManifestValidationError::InvalidHostPermissions)
    );
}

// @Test("host rules cannot smuggle a path, credentials or a port range")
#[test]
fn http_host_patterns_are_bounded() {
    for invalid in [
        r#"["https://api.example.com"]"#,
        r#"["user@api.example.com"]"#,
        r#"["api.example.com/v1"]"#,
        r#"["*"]"#,
        r#"[]"#,
    ] {
        let document = manifest(&format!(
            r#"{{"http": [{{"id": "api", "hosts": {invalid}}}]}}"#
        ));
        assert_eq!(
            decode(&document),
            Err(PluginManifestValidationError::InvalidHostPermissions),
            "hosts {invalid} must be rejected"
        );
    }
    let wildcard = decode(&manifest(
        r#"{"http": [{"id": "api", "hosts": ["*.example.com"]}]}"#,
    ))
    .expect("wildcard manifest");
    assert!(
        wildcard
            .host
            .http
            .first()
            .is_some_and(|rule| rule.allows("api.example.com"))
    );
    assert!(
        !wildcard
            .host
            .http
            .first()
            .is_some_and(|rule| rule.allows("example.com"))
    );
}

// @Test("an agent contribution is validated")
#[test]
fn agent_contribution_is_validated() {
    fn agent_manifest(contributes: &str) -> Vec<u8> {
        format!(
            r#"
            {{"id": "test.agent", "version": 1, "name": "Agent", "description": "fixture",
             "access": "read", "imports": [], "composable_host_capabilities": [],
             "contributes": {contributes}}}
            "#
        )
        .into_bytes()
    }
    let valid = decode(&agent_manifest(
        r#"
        {"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "instructions": "Be brief.",
          "model": {"preferred": "claude-sonnet-4-6", "maxOutputTokens": 4096},
          "tools": ["read_file", "scene.set_name"], "context": ["scene", "git-summary"]}]}
        "#,
    ))
    .expect("valid agent");
    let agents: Vec<AgentContribution> = valid
        .contributes
        .decode::<AgentContributionPoint>()
        .expect("decodes agents");
    assert_eq!(
        agents
            .first()
            .and_then(|agent| agent.model.as_ref())
            .and_then(|model| model.preferred.as_deref()),
        Some("claude-sonnet-4-6")
    );
    assert_eq!(
        agents.first().and_then(|agent| agent.context.clone()),
        Some(vec!["scene".to_string(), "git-summary".to_string()])
    );

    for invalid in [
        r#"{"cove.ai.agent/v1": [{"id": "Assistant", "title": "Assistant"}]}"#,
        r#"{"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "model": {"preferred": ""}}]}"#,
        r#"{"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "tools": ["Read File"]}]}"#,
        r#"{"cove.ai.agent/v1": [{"id": "assistant", "title": "Assistant", "context": ["scene", "scene"]}]}"#,
    ] {
        assert_eq!(
            decode(&agent_manifest(invalid)),
            Err(PluginManifestValidationError::InvalidContribution(
                "cove.ai.agent/v1".to_string()
            )),
            "{invalid} must be rejected"
        );
    }
}
