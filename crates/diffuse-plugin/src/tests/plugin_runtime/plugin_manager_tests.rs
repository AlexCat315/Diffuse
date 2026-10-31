//! Ported from `Engine/Tests/PluginRuntimeTests/PluginManagerTests.swift`.
//!
//! Swift's suite was `@MainActor` because the manager serialised on the main
//! actor; the Rust manager serialises on its own mutex (MIGRATION.md §5.5), so
//! the analogous test is plain.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use diffuse_capability::capability_contract::CapabilityAccess;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::support::disposal::{DisposalScope, Registration};
use diffuse_capability::support::swift_date::SwiftDate;

use crate::contract::activation::PluginActivationEvent;
use crate::contract::plugin_manifest::CovePluginManifest;
use crate::contract::plugin_package::PluginPackageLoader;
use crate::contract::requirements::{PluginRequirement, PluginRequirementKind};
use crate::contribution::ai::models::{AIModelContribution, AIProviderContribution};
use crate::contribution::ai::provider_point::AIProviderContributionPoint;
use crate::contribution::catalog::ContributionCatalog;
use crate::contribution::languages::language::LanguageContribution;
use crate::contribution::languages::language_point::LanguageContributionPoint;
use crate::contribution::registrar::ContributionRegistrar;
use crate::contribution::registry::ContributionPointRegistry;
use crate::lifecycle::manager::PluginManager;
use crate::lifecycle::status::{
    PluginManagerError, PluginPhase, PluginRuntimeActivation, PluginRuntimeDriver,
};
use crate::plugin_authorization::{
    PluginAuthorizationError, PluginAuthorizationRecord, PluginContractDeriver, PluginInspection,
};
use crate::uuid::Uuid;

#[derive(Default)]
struct Calls {
    recorded: Mutex<Vec<String>>,
}

impl Calls {
    fn new() -> Self {
        Calls::default()
    }

    fn add(&self, value: impl Into<String>) {
        self.recorded
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .push(value.into());
    }

    fn values(&self) -> Vec<String> {
        self.recorded
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone()
    }
}

fn loader() -> PluginPackageLoader {
    PluginPackageLoader::new(
        CapabilityRegistry::default_registry(),
        None,
        ContributionPointRegistry::standard(),
    )
}

fn package(
    id: &str,
    runtime: bool,
    events: Vec<String>,
    requires: Vec<PluginRequirement>,
) -> PathBuf {
    let root = std::env::temp_dir().join(format!("{}.coveplugin", Uuid::new()));
    std::fs::create_dir_all(&root).expect("temp package");
    let mut manifest = CovePluginManifest::new(
        id,
        1,
        id,
        "Fixture",
        CapabilityAccess::Read,
        Vec::new(),
        Vec::new(),
        requires,
        Default::default(),
        Default::default(),
    );
    manifest.activation = events;
    if runtime {
        manifest.runtime = Some(Default::default());
    } else {
        manifest
            .contributes
            .set::<LanguageContributionPoint>(&[LanguageContribution::new(
                // Swift's fixture: `LanguageContribution(id: "fixture", …)`.
                "fixture",
                "Fixture",
                vec!["fixture".to_string()],
            )])
            .expect("sets contribution");
    }
    std::fs::write(
        root.join("plugin.json"),
        serde_json::to_vec(&manifest).expect("encodes manifest"),
    )
    .expect("writes manifest");
    if runtime {
        std::fs::write(root.join("plugin.js"), "export default {}").expect("writes component");
        std::fs::write(
            root.join("capabilities.json"),
            br#"{"version":1,"entries":[{"name":"inspect","title":"Inspect","description":"","input":{"record":{"enabled":"bool"}}}]}"#,
        )
        .expect("writes contract");
    }
    root
}

fn authorize(url: &std::path::Path) -> PluginAuthorizationRecord {
    let package = loader().load(url).expect("loads package");
    PluginAuthorizationRecord::from_inspection(
        &PluginInspection::from_package(&package, PluginContractDeriver::contracts(&package)),
        SwiftDate(0.0),
    )
    .expect("authorizes")
}

fn driver(calls: std::sync::Arc<Calls>, failing: Option<&'static str>) -> PluginRuntimeDriver {
    let activate_calls = calls.clone();
    let deactivate_calls = calls.clone();
    PluginRuntimeDriver::new(
        move |url, authorization| {
            let calls = activate_calls.clone();
            let package = loader().load(&url).expect("loads package");
            calls.add(format!("activate:{}", package.manifest.id));
            if Some(package.manifest.id.as_str()) == failing {
                return Err(PluginManagerError::RuntimeUnavailable.into());
            }
            let inspection = PluginInspection::from_package(
                &package,
                PluginContractDeriver::contracts(&package),
            );
            let binding = crate::plugin_authorization::PluginExecutionBinding::new(
                url.to_string_lossy().into_owned(),
                inspection,
                authorization,
                1,
            )
            .map_err(crate::PluginError::from)?;
            Ok(PluginRuntimeActivation::new(binding, None))
        },
        move |binding| {
            deactivate_calls.add(format!("deactivate:{}", binding.plugin_id()));
            Ok(())
        },
        move || calls.add("stop"),
    )
}

// @Test("registrations release in reverse order, once, even when release throws")
#[test]
fn disposal() {
    let calls = std::sync::Arc::new(Calls::new());
    let scope = DisposalScope::new();
    let first = calls.clone();
    scope.track(move || first.add("first"));
    let second = calls.clone();
    scope.track_registration(std::sync::Arc::new(Registration::new(move || {
        second.add("second");
    })));
    let third = calls.clone();
    scope.track(move || third.add("third"));
    // The shared `Registration` records no failure channel, so a throwing release
    // is spelled as a release that records the same evidence; ordering is what
    // this assertion pins.
    scope.dispose_all();
    scope.dispose_all();
    let late = calls.clone();
    scope.track(move || late.add("late"));
    assert_eq!(calls.values(), vec!["third", "second", "first"]);
}

// @Test("enabled declarations survive without a host and disappear on disable")
#[test]
fn declarations() {
    let url = package("fixture.lazy", false, Vec::new(), Vec::new());
    let catalog = std::sync::Arc::new(ContributionCatalog::<LanguageContribution>::new());
    let mut registrar = ContributionRegistrar::new();
    {
        let catalog = catalog.clone();
        registrar
            .register::<LanguageContributionPoint, _>(move |values, package| {
                Ok(catalog.register(values.to_vec(), &package.manifest.id)?)
            })
            .expect("registers language point");
    }
    let manager = PluginManager::new(registrar, loader(), BTreeMap::new());
    manager.install(&url).expect("installs");
    assert_eq!(
        manager.statuses().first().map(|status| status.phase),
        Some(PluginPhase::Installed)
    );
    manager.enable(&url, &authorize(&url)).expect("enables");
    assert_eq!(
        manager.statuses().first().map(|status| status.phase),
        Some(PluginPhase::Enabled)
    );
    assert_eq!(catalog.snapshot().values.len(), 1);
    manager.reload("fixture.lazy").expect("reloads");
    assert_eq!(catalog.snapshot().values.len(), 1);
    manager.disable("fixture.lazy").expect("disables");
    assert!(catalog.snapshot().values.is_empty());
    assert_eq!(
        manager.statuses().first().map(|status| status.phase),
        Some(PluginPhase::Installed)
    );
    manager.uninstall("fixture.lazy").expect("uninstalls");
    assert!(manager.statuses().is_empty());
    let _ = std::fs::remove_dir_all(&url);
}

// @Test("runtime stays dormant until demand and concurrent demand activates once")
#[test]
fn lazy_activation() {
    let url = package(
        "fixture.lazy",
        true,
        vec!["onView:fixture".to_string()],
        Vec::new(),
    );
    let calls = std::sync::Arc::new(Calls::new());
    let manager = PluginManager::new(ContributionRegistrar::new(), loader(), BTreeMap::new());
    manager.configure_runtime(driver(calls.clone(), None));
    manager.enable(&url, &authorize(&url)).expect("enables");
    manager.reload("fixture.lazy").expect("reloads");
    manager
        .activate_event("onLanguage:other")
        .expect("activates unrelated event");
    assert!(calls.values().is_empty());
    // Swift started two concurrent `Task`s; the manager's mutex serialises them
    // and the binding check makes the second a no-op.
    manager
        .activate_event("onView:fixture")
        .expect("activates first demand");
    manager
        .activate_event("onView:fixture")
        .expect("activates second demand");
    assert_eq!(calls.values(), vec!["activate:fixture.lazy"]);
    assert_eq!(
        manager.statuses().first().map(|status| status.phase),
        Some(PluginPhase::Activated)
    );
    manager.disable("fixture.lazy").expect("disables");
    assert_eq!(
        calls.values(),
        vec!["activate:fixture.lazy", "deactivate:fixture.lazy"]
    );
    let _ = std::fs::remove_dir_all(&url);
}

// @Test("dependency demand activates providers first; failure withdraws dependents only")
#[test]
fn dependency_activation() {
    let provider = package("fixture.provider", true, Vec::new(), Vec::new());
    let dependent = package(
        "fixture.dependent",
        true,
        Vec::new(),
        vec![PluginRequirement::new(
            PluginRequirementKind::Capability,
            "fixture.provider.inspect",
        )],
    );
    let data = package("fixture.data", false, Vec::new(), Vec::new());
    let catalog = std::sync::Arc::new(ContributionCatalog::<LanguageContribution>::new());
    let mut registrar = ContributionRegistrar::new();
    {
        let catalog = catalog.clone();
        registrar
            .register::<LanguageContributionPoint, _>(move |values, package| {
                Ok(catalog.register(values.to_vec(), &package.manifest.id)?)
            })
            .expect("registers language point");
    }
    let calls = std::sync::Arc::new(Calls::new());
    let manager = PluginManager::new(registrar, loader(), BTreeMap::new());
    manager.configure_runtime(driver(calls.clone(), Some("fixture.provider")));
    for url in [&provider, &dependent, &data] {
        manager.enable(url, &authorize(url)).expect("enables");
    }
    assert!(matches!(
        manager.activate("fixture.dependent"),
        Err(crate::PluginError::Manager(
            PluginManagerError::RuntimeUnavailable
        ))
    ));
    let mut enabled: Vec<String> = manager.enabled_manifests().into_keys().collect();
    enabled.sort();
    assert_eq!(enabled, vec!["fixture.data"]);
    assert_eq!(catalog.snapshot().values.len(), 1);
    assert_eq!(calls.values(), vec!["activate:fixture.provider"]);
    assert_eq!(
        manager
            .statuses()
            .iter()
            .filter(|status| status.phase == PluginPhase::Failed)
            .count(),
        2
    );
    for url in [&provider, &dependent, &data] {
        let _ = std::fs::remove_dir_all(url);
    }
}

// @Test("disabling an owner withdraws dependent plugins before the owner")
#[test]
fn disable_cascades() {
    let provider = package("fixture.provider", true, Vec::new(), Vec::new());
    let dependent = package(
        "fixture.dependent",
        true,
        Vec::new(),
        vec![PluginRequirement::new(
            PluginRequirementKind::Plugin,
            "fixture.provider",
        )],
    );
    let calls = std::sync::Arc::new(Calls::new());
    let manager = PluginManager::new(ContributionRegistrar::new(), loader(), BTreeMap::new());
    manager.configure_runtime(driver(calls.clone(), None));
    for url in [&provider, &dependent] {
        manager.enable(url, &authorize(url)).expect("enables");
    }
    manager.activate("fixture.dependent").expect("activates");
    manager.disable("fixture.provider").expect("disables");
    assert!(manager.enabled_manifests().is_empty());
    assert_eq!(
        calls
            .values()
            .into_iter()
            .rev()
            .take(2)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<Vec<_>>(),
        vec![
            "deactivate:fixture.dependent".to_string(),
            "deactivate:fixture.provider".to_string()
        ]
    );
    for url in [&provider, &dependent] {
        let _ = std::fs::remove_dir_all(url);
    }
}

// @Test("startup remembered before enable; workspace globs and URI events route precisely")
#[test]
fn remembered_events() {
    let url = package(
        "fixture.lazy",
        true,
        vec!["onStartup".to_string()],
        Vec::new(),
    );
    let calls = std::sync::Arc::new(Calls::new());
    let manager = PluginManager::new(ContributionRegistrar::new(), loader(), BTreeMap::new());
    manager.configure_runtime(driver(calls.clone(), None));
    manager
        .activate_event("onStartup")
        .expect("records startup");
    manager.enable(&url, &authorize(&url)).expect("enables");
    assert_eq!(
        manager.statuses().first().map(|status| status.phase),
        Some(PluginPhase::Activated)
    );
    assert!(PluginManager::matches(
        "onWorkspaceContains:**/Package.*",
        "onWorkspaceContains:App/Package.swift"
    ));
    assert!(!PluginManager::matches("onURI:cove", "onURI:other"));
    assert!(!PluginActivationEvent::is_valid("onView:"));
    let _ = std::fs::remove_dir_all(&url);
}

// @Test("registration failure rolls back preceding domain registrations")
#[test]
fn registration_rollback() {
    let url = package("fixture.lazy", false, Vec::new(), Vec::new());
    let mut manifest = loader().load(&url).expect("loads").manifest;
    manifest
        .contributes
        .set::<AIProviderContributionPoint>(&[AIProviderContribution::new(
            "fixture",
            "Fixture",
            "openai-compatible",
            vec![AIModelContribution::new("fixture", "Fixture")],
        )])
        .expect("sets provider");
    std::fs::write(
        url.join("plugin.json"),
        serde_json::to_vec(&manifest).expect("encodes"),
    )
    .expect("writes manifest");
    let calls = std::sync::Arc::new(Calls::new());
    let mut registrar = ContributionRegistrar::new();
    {
        let calls = calls.clone();
        registrar
            .register::<AIProviderContributionPoint, _>(move |_, _| {
                calls.add("register:provider");
                let calls = calls.clone();
                Ok(std::sync::Arc::new(Registration::new(move || {
                    calls.add("dispose:provider");
                })))
            })
            .expect("registers provider");
    }
    {
        let calls = calls.clone();
        registrar
            .register::<LanguageContributionPoint, _>(move |_, _| {
                calls.add("register:language");
                Err(PluginManagerError::RuntimeUnavailable.into())
            })
            .expect("registers language");
    }
    let manager = PluginManager::new(registrar, loader(), BTreeMap::new());
    assert!(matches!(
        manager.enable(&url, &authorize(&url)),
        Err(crate::PluginError::Manager(
            PluginManagerError::RuntimeUnavailable
        ))
    ));
    assert!(manager.enabled_inspections().is_empty());
    assert_eq!(
        manager.statuses().first().map(|status| status.phase),
        Some(PluginPhase::Failed)
    );
    assert_eq!(
        calls.values(),
        vec!["register:provider", "register:language", "dispose:provider"]
    );
    let _ = std::fs::remove_dir_all(&url);
}

// @Test("stop during activation cannot resurrect a binding")
#[test]
fn stop_during_activation() {
    let url = package("fixture.lazy", true, Vec::new(), Vec::new());
    let calls = std::sync::Arc::new(Calls::new());
    let manager = PluginManager::new(ContributionRegistrar::new(), loader(), BTreeMap::new());
    manager.configure_runtime(driver(calls.clone(), None));
    manager.enable(&url, &authorize(&url)).expect("enables");
    manager.stop();
    assert!(matches!(
        manager.activate("fixture.lazy"),
        Err(crate::PluginError::Manager(PluginManagerError::Stopped))
            | Err(crate::PluginError::Authorization(
                PluginAuthorizationError::NoLongerValid
            ))
    ));
    assert!(manager.statuses().is_empty());
    assert!(manager.active_bindings().is_empty());
    let _ = std::fs::remove_dir_all(&url);
}

// @Test("runtime invalidation releases dependents before providers and leaves data enabled")
#[test]
fn runtime_invalidation() {
    let provider = package("fixture.provider", true, Vec::new(), Vec::new());
    let dependent = package(
        "fixture.dependent",
        true,
        Vec::new(),
        vec![PluginRequirement::new(
            PluginRequirementKind::Plugin,
            "fixture.provider",
        )],
    );
    let data = package("fixture.data", false, Vec::new(), Vec::new());
    let mut registrar = ContributionRegistrar::new();
    registrar
        .register::<LanguageContributionPoint, _>(|_, _| {
            Ok(std::sync::Arc::new(Registration::new(|| {})))
        })
        .expect("registers language point");
    let calls = std::sync::Arc::new(Calls::new());
    let manager = PluginManager::new(registrar, loader(), BTreeMap::new());
    manager.configure_runtime(driver(calls.clone(), None));
    for url in [&provider, &dependent, &data] {
        manager.enable(url, &authorize(url)).expect("enables");
    }
    manager.activate("fixture.dependent").expect("activates");
    assert_eq!(
        calls.values(),
        vec!["activate:fixture.provider", "activate:fixture.dependent"]
    );
    assert_eq!(manager.invalidate_runtime(Some(1)).ok(), Some(false));
    assert_eq!(manager.active_bindings().len(), 2);
    assert_eq!(manager.invalidate_runtime(Some(2)).ok(), Some(true));
    let mut enabled: Vec<String> = manager.enabled_manifests().into_keys().collect();
    enabled.sort();
    assert_eq!(enabled, vec!["fixture.data"]);
    let tail: Vec<String> = calls.values().into_iter().rev().take(2).rev().collect();
    assert_eq!(
        tail,
        vec![
            "deactivate:fixture.dependent".to_string(),
            "deactivate:fixture.provider".to_string()
        ]
    );
    for url in [&provider, &dependent, &data] {
        let _ = std::fs::remove_dir_all(url);
    }
}
