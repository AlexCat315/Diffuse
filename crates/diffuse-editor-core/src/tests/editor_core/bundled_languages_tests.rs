//! Ported from `Editor/Tests/EditorCoreTests/BundledLanguagesTests.swift`.
//!
//! `formattingActivatesOnDemandWithoutResettingChat` asserts editor-application
//! behaviour (bundled plugin activation, `formatDocument`, chat state) that has
//! no Rust counterpart yet: there is no `EditorApplication` shell and
//! `application/plugins/document_formatting.rs` / `plugin_session.rs` are still
//! empty placeholders. The two package-level cases are translated below; they
//! need the packaged `DiffuseEditor_EditorCore` resource bundle and, for the
//! format capability, a runnable Bun.

use cove_platform::ResourceBundle;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::PluginError;
use diffuse_plugin::contract::plugin_manifest::PluginResourceLimits;
use diffuse_plugin::contract::plugin_package::{PluginPackageLoader, ValidatedPluginPackage};
use diffuse_plugin::contribution::languages::language::LanguageContribution;
use diffuse_plugin::contribution::languages::language_point::LanguageContributionPoint;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;
use diffuse_plugin::host::bun_runtime::{BunPluginRuntime, BunRuntimeError};
use diffuse_plugin::network::transfers::PluginHTTPService;
use diffuse_plugin::processes::service::PluginProcessService;

use crate::application::plugins::bundled::BundledPlugins;

/// The packaged editor resources; absent in an unpackaged test run, matching
/// the deployment error Swift's resource bundle raised.
fn editor_bundle() -> Option<ResourceBundle> {
    ResourceBundle::beside_executable(&[
        "DiffuseEditor_EditorCore",
        "DiffuseEditor_EditorCore.resources",
    ])
    .ok()
    .flatten()
}

fn load_studio_languages() -> Option<ValidatedPluginPackage> {
    editor_bundle()?;
    let plugin =
        BundledPlugins::plugin("studio.languages").expect("bundled studio.languages plugin");
    let loader = PluginPackageLoader::new(
        CapabilityRegistry::default_registry(),
        None,
        ContributionPointRegistry::standard(),
    );
    Some(
        loader
            .load(&plugin.package)
            .expect("load studio.languages package"),
    )
}

fn languages(package: &ValidatedPluginPackage) -> Vec<LanguageContribution> {
    package
        .manifest
        .contributes
        .decode::<LanguageContributionPoint>()
        .unwrap_or_default()
}

fn latex_language(package: &ValidatedPluginPackage) -> LanguageContribution {
    languages(package)
        .into_iter()
        .find(|language| language.id == "latex")
        .expect("latex language contribution")
}

/// The `format` capability formats a whole document through the Bun runtime.
#[test]
fn latex_format_capability_formats_whole_document() {
    let Some(package) = load_studio_languages() else {
        return;
    };
    let format = latex_language(&package)
        .format
        .expect("latex format contribution");
    assert_eq!(format.entry_point, "format");

    let mut runtime = BunPluginRuntime::new(PluginProcessService::new(), PluginHTTPService::new());
    let input = serde_json::to_vec(&serde_json::json!({
        "text": "first  \r\n\r\n\r\nsecond\t\n",
    }))
    .expect("encode format input");
    let capability_id = format!("{}.{}", package.manifest.id, format.entry_point);
    match runtime.prepare(
        &package,
        &capability_id,
        &input,
        None,
        &PluginResourceLimits::secure_default(),
    ) {
        Ok(output) => {
            let formatted: String =
                serde_json::from_slice(&output).expect("decode formatted document");
            assert_eq!(formatted, "first\n\nsecond\n");
        }
        // Unpackaged runs carry no Bun binary or runner; the packaged editor
        // always ships both, where the assertion above applies.
        Err(PluginError::Bun(BunRuntimeError::Unavailable)) => {}
        Err(error) => panic!("latex format capability failed: {error}"),
    }
}

/// The package declares the latex grammar, outline and format entry point.
#[test]
fn language_grammar_and_outline_are_declared_by_the_package() {
    let Some(package) = load_studio_languages() else {
        return;
    };
    let latex = latex_language(&package);
    assert!(
        latex
            .grammar
            .as_ref()
            .is_some_and(|grammar| !grammar.rules.is_empty())
    );
    assert!(
        latex
            .outline
            .as_ref()
            .is_some_and(|outline| !outline.rules.is_empty())
    );
    assert_eq!(
        latex
            .format
            .as_ref()
            .map(|format| format.entry_point.as_str()),
        Some("format")
    );
}
