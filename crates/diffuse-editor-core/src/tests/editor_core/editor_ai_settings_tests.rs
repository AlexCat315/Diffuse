//! Ported from `Editor/Tests/EditorCoreTests/EditorAISettingsTests.swift`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::ai::chat::editor_ai_settings::{AICredentialStore, environment_credential};

fn temporary_root(prefix: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()))
}

fn environment(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
        .collect()
}

fn fields(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
        .collect()
}

fn remove_temporary_root(url: &Path) {
    let _ = std::fs::remove_dir_all(url);
}

/// Only the provider's declared variable is consulted, even when the standard
/// vendor variable is present.
#[test]
fn environment_credentials_use_only_the_declared_variable() {
    let credential = environment_credential(
        Some("COVE_OPENAI_API_KEY"),
        &environment(&[
            ("OPENAI_API_KEY", "standard"),
            ("COVE_OPENAI_API_KEY", "override"),
        ]),
    )
    .expect("declared variable");

    assert_eq!(credential.variable, "COVE_OPENAI_API_KEY");
    assert_eq!(credential.key, "override");
}

/// Every remote provider works through its own variable; blank values and an
/// absent variable are rejected.
#[test]
fn environment_credentials_support_every_remote_provider_and_reject_blanks() {
    assert_eq!(
        environment_credential(
            Some("ANTHROPIC_API_KEY"),
            &environment(&[("ANTHROPIC_API_KEY", " anthropic-key ")])
        )
        .map(|credential| credential.key),
        Some("anthropic-key".to_string())
    );
    assert_eq!(
        environment_credential(
            Some("DEEPSEEK_API_KEY"),
            &environment(&[("DEEPSEEK_API_KEY", "deepseek-key")])
        )
        .map(|credential| credential.variable),
        Some("DEEPSEEK_API_KEY".to_string())
    );
    assert!(
        environment_credential(
            Some("OPENAI_API_KEY"),
            &environment(&[("OPENAI_API_KEY", "  ")])
        )
        .is_none()
    );
    assert!(environment_credential(None, &environment(&[("OPENAI_API_KEY", "ignored")])).is_none());
}

/// The credential file is owner-only and round-trips; an empty value removes
/// that field and the last field removes the provider.
#[test]
fn credential_file_is_owner_only_and_round_trips() {
    let root = temporary_root("cove-ai-credentials");
    let url = root.join("Credentials").join("ai-providers.json");

    AICredentialStore::save_at(
        &fields(&[("api-key", "sk-one"), ("organization", "org-1")]),
        "anthropic",
        &url,
    )
    .expect("save anthropic");
    AICredentialStore::save_at(&fields(&[("api-key", "sk-two")]), "openai", &url)
        .expect("save openai");
    assert_eq!(
        AICredentialStore::stored(&url),
        BTreeMap::from([
            (
                "anthropic".to_string(),
                BTreeMap::from([
                    ("api-key".to_string(), "sk-one".to_string()),
                    ("organization".to_string(), "org-1".to_string()),
                ]),
            ),
            (
                "openai".to_string(),
                BTreeMap::from([("api-key".to_string(), "sk-two".to_string())]),
            ),
        ])
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let file = std::fs::metadata(&url).expect("credential file");
        let folder = std::fs::metadata(url.parent().expect("credentials folder"))
            .expect("credentials folder");
        assert_eq!(file.permissions().mode() & 0o777, 0o600);
        assert_eq!(folder.permissions().mode() & 0o777, 0o700);
    }

    AICredentialStore::save_at(&fields(&[("organization", "")]), "anthropic", &url)
        .expect("clear organization");
    assert_eq!(
        AICredentialStore::stored(&url)
            .get("anthropic")
            .cloned()
            .unwrap_or_default(),
        BTreeMap::from([("api-key".to_string(), "sk-one".to_string())])
    );

    AICredentialStore::save_at(&fields(&[("api-key", "")]), "anthropic", &url)
        .expect("clear api key");
    assert_eq!(
        AICredentialStore::stored(&url),
        BTreeMap::from([(
            "openai".to_string(),
            BTreeMap::from([("api-key".to_string(), "sk-two".to_string())]),
        )])
    );

    remove_temporary_root(&root);
}
