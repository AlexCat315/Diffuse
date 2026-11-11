//! `Editor/Sources/EditorCore/Contributions/Languages.swift`.

use std::path::Path;
use std::sync::OnceLock;

use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::contract::host_permissions::PluginProcessPermission;
use diffuse_plugin::contract::plugin_manifest::CovePluginManifest;
use diffuse_plugin::contract::plugin_package::{PluginPackageLoader, ValidatedPluginPackage};
use diffuse_plugin::contribution::languages::language::{
    LanguageContribution, LanguageServerContribution, SyntaxToken,
};
use diffuse_plugin::contribution::languages::language_point::LanguageContributionPoint;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;

use crate::application::plugins::bundled::BundledPlugins;

/// A language a plugin contributes, with the permission that starts its server.
#[derive(Clone, Debug)]
pub(crate) struct ContributedLanguage {
    pub(crate) plugin_id: String,
    pub(crate) language: LanguageContribution,
    pub(crate) server: Option<(LanguageServerContribution, PluginProcessPermission)>,
}

impl ContributedLanguage {
    pub(crate) fn icon_key(&self) -> String {
        self.language
            .icon
            .clone()
            .unwrap_or_else(|| self.language.id.clone())
    }

    pub(crate) fn matches(&self, path: &str) -> bool {
        let extension = Path::new(path)
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        self.language
            .extensions
            .iter()
            .any(|candidate| candidate == extension)
    }
}

/// A language's user-facing identity: what a document path looks like, without
/// the plugin or server details behind it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LanguageDescriptor {
    pub id: String,
    pub title: String,
    pub extensions: Vec<String>,
    pub icon_key: String,
}

/// One declarative colouring rule, already narrowed to the host's token set.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LanguageSyntaxRule {
    pub pattern: String,
    pub token: SyntaxToken,
}

impl LanguageSyntaxRule {
    pub fn new(pattern: impl Into<String>, token: SyntaxToken) -> Self {
        LanguageSyntaxRule {
            pattern: pattern.into(),
            token,
        }
    }
}

/// One declarative heading rule: capture group 1 is the title.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LanguageOutlineRule {
    pub pattern: String,
    pub level: i64,
}

impl LanguageOutlineRule {
    pub fn new(pattern: impl Into<String>, level: i64) -> Self {
        LanguageOutlineRule {
            pattern: pattern.into(),
            level,
        }
    }
}

/// The enabled package and entry point that format this language.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LanguageFormat {
    pub plugin_id: String,
    pub entry_point: String,
}

impl LanguageFormat {
    pub fn new(plugin_id: impl Into<String>, entry_point: impl Into<String>) -> Self {
        LanguageFormat {
            plugin_id: plugin_id.into(),
            entry_point: entry_point.into(),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct LanguageCatalog {
    pub(crate) languages: Vec<ContributedLanguage>,
}

impl LanguageCatalog {
    /// File recognition outside a project uses immutable bundled metadata.
    pub fn bundled() -> &'static LanguageCatalog {
        static BUNDLED: OnceLock<LanguageCatalog> = OnceLock::new();
        BUNDLED.get_or_init(|| {
            let loader = default_loader();
            let packages: Vec<ValidatedPluginPackage> = BundledPlugins::catalog()
                .iter()
                .filter_map(|plugin| loader.load(&plugin.package).ok())
                .collect();
            LanguageCatalog::from_packages(packages)
        })
    }

    pub(crate) fn served() -> Option<&'static ContributedLanguage> {
        Self::bundled()
            .languages
            .iter()
            .find(|language| language.server.is_some())
    }

    /// Swift's `packages: [ValidatedPluginPackage] = []` default.
    pub fn with_default_packages() -> Self {
        LanguageCatalog {
            languages: Vec::new(),
        }
    }

    pub fn from_packages(mut packages: Vec<ValidatedPluginPackage>) -> Self {
        packages.sort_by(|left, right| left.manifest.id.cmp(&right.manifest.id));
        let languages = packages
            .into_iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode::<LanguageContributionPoint>()
                    .unwrap_or_default()
                    .into_iter()
                    .map(move |language| ContributedLanguage {
                        plugin_id: package.manifest.id.clone(),
                        server: server_of(&language, &package.manifest),
                        language,
                    })
            })
            .collect();
        LanguageCatalog { languages }
    }

    /// Whether any enabled package contributes a language service. The UI asks
    /// this instead of naming a plugin, so a different package can serve the
    /// language without any editor change.
    pub fn has_language_service(&self) -> bool {
        self.languages
            .iter()
            .any(|language| language.server.is_some())
    }

    pub fn descriptor_for_extension(&self, extension: &str) -> Option<LanguageDescriptor> {
        let extension = extension.to_lowercase();
        if extension.is_empty() {
            return None;
        }
        let language = self.languages.iter().find(|language| {
            language
                .language
                .extensions
                .iter()
                .any(|candidate| candidate == &extension)
        })?;
        Some(LanguageDescriptor {
            id: language.language.id.clone(),
            title: language.language.title.clone(),
            extensions: language.language.extensions.clone(),
            icon_key: language.icon_key(),
        })
    }

    pub fn syntax_rules(&self, language_id: Option<&str>) -> Vec<LanguageSyntaxRule> {
        let Some(language) = self.language(language_id) else {
            return Vec::new();
        };
        let Some(grammar) = language.language.grammar.as_ref() else {
            return Vec::new();
        };
        grammar
            .rules
            .iter()
            .filter_map(|rule| {
                SyntaxToken::from_raw_value(&rule.token)
                    .map(|token| LanguageSyntaxRule::new(rule.pattern.clone(), token))
            })
            .collect()
    }

    pub fn outline_rules(&self, language_id: Option<&str>) -> Vec<LanguageOutlineRule> {
        let Some(language) = self.language(language_id) else {
            return Vec::new();
        };
        let Some(outline) = language.language.outline.as_ref() else {
            return Vec::new();
        };
        outline
            .rules
            .iter()
            .map(|rule| LanguageOutlineRule::new(rule.pattern.clone(), rule.level))
            .collect()
    }

    pub fn format(&self, language_id: Option<&str>) -> Option<LanguageFormat> {
        let language = self.language(language_id)?;
        let format = language.language.format.as_ref()?;
        Some(LanguageFormat::new(
            language.plugin_id.clone(),
            format.entry_point.clone(),
        ))
    }

    fn language(&self, id: Option<&str>) -> Option<&ContributedLanguage> {
        let id = id?;
        self.languages
            .iter()
            .find(|language| language.language.id == id)
    }
}

fn server_of(
    language: &LanguageContribution,
    manifest: &CovePluginManifest,
) -> Option<(LanguageServerContribution, PluginProcessPermission)> {
    let server = language.server.as_ref()?;
    let process = manifest
        .host
        .processes
        .iter()
        .find(|process| process.id == server.process)?;
    Some((server.clone(), process.clone()))
}

/// `PluginPackageLoader()` with its Swift default arguments.
fn default_loader() -> PluginPackageLoader {
    PluginPackageLoader::new(
        CapabilityRegistry::default(),
        None,
        ContributionPointRegistry::standard(),
    )
}
