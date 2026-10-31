//! Verifies ownership between the standalone SDK and Studio packages.

use super::manifest::{DumpPackage, ManifestLoader, canonical_path};
use crate::support::files;
use crate::support::repository;
use crate::support::shell;
use crate::support::terminal::{Terminal, ToolError};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

const DEMO_PRODUCTS: [&'static str; 5] = [
    "CoveUIDemo",
    "PetDemo",
    "GalleryContent",
    "CounterExample",
    "CoveUIApp",
];
/// Scene, physics and render-backend products belong to Studio.
const ENGINE_ONLY_PRODUCTS: [&'static str; 8] = [
    "RenderBackend",
    "SceneRuntime",
    "CardBattleRuntime",
    "CinematicRenderer",
    "SequenceRuntime",
    "PerceptionRuntime",
    "SemanticPipeline",
    "EngineCore",
];
/// Compose, window and workspace products belong to the SDK; the engine
/// integrates with it only through the host boundary.
const UI_ONLY_PRODUCTS: [&'static str; 7] = [
    "CoveUI",
    "CoveUICompose",
    "CoveUIComposeCore",
    "CoveUIWorkspace",
    "CoveUIRuntime",
    "CoveUIWebView",
    "PlatformShell",
];
const SUPPORTED_PLATFORMS: [&'static str; 5] = ["mac", "win", "linux", "android", "ios"];
const SUCCESS: &'static str = "Module boundaries passed: production UI, workspace launcher, Android application/game/showcase, and application templates";

pub struct BoundaryChecks {
    root: PathBuf,
    sdk_root: PathBuf,
    application: PathBuf,
    loader: ManifestLoader,
}

impl BoundaryChecks {
    pub fn new(root: &Path, environment: &BTreeMap<String, String>) -> Self {
        let root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
        let sdk_root = canonical_path(
            environment.get("COVE_SDK_ROOT").map(String::as_str).unwrap_or("CoveUI"),
            &root,
        );
        let application = std::env::temp_dir().join(format!(
            "cove-boundary-{}",
            std::process::id()
        ));
        let loader = ManifestLoader::new(&root, environment);
        Self {
            root,
            sdk_root,
            application,
            loader,
        }
    }

    pub fn perform(&mut self) -> Result<(), ToolError> {
        let guard = TempGuard(self.application.clone());
        let command = if cfg!(windows) {
            let binary = self.sdk_root.join("cove.exe");
            if binary.exists() {
                binary
            } else {
                self.sdk_root.join("cove.cmd")
            }
        } else {
            self.sdk_root.join("cove")
        };
        shell::inherit(
            &[
                command.display().to_string(),
                "create".into(),
                "app".into(),
                self.application.display().to_string(),
                "--sdk-root".into(),
                self.sdk_root.display().to_string(),
            ],
            None,
            &std::env::vars().collect(),
            None,
        )?;
        let ui = self.loader.manifest(&self.sdk_root.clone(), &BTreeMap::new())?.clone();
        Self::require(
            ui.product_names.contains("CoveUI"),
            "CoveUI must remain a production product",
        )?;
        let leaked: Vec<&str> = DEMO_PRODUCTS
            .iter()
            .copied()
            .filter(|product| ui.product_names.contains(*product))
            .collect();
        Self::require(
            leaked.is_empty(),
            &format!(
                "CoveUI must not vend demo or example products: {}",
                leaked.join(", ")
            ),
        )?;
        let launcher = ui.target("CoveUI")?;
        Self::require(
            !launcher.by_name.contains("CoveUIWorkspace"),
            "CoveUI must not depend on the CoveUIWorkspace launcher target",
        )?;

        let inspection_directory = self.sdk_root.join("DevTools/Inspection");
        let portable = self
            .loader
            .manifest(&inspection_directory, &BTreeMap::new())?
            .clone();
        for (name, package) in [("CoveUI", &ui), ("CoveUI/DevTools/Inspection", &portable)] {
            for dependency in &package.local_dependencies {
                if dependency
                    .display()
                    .to_string()
                    .to_lowercase()
                    .contains("examples")
                {
                    return Err(ToolError::message(format!(
                        "{name} must not depend on an examples package: {}",
                        dependency.display()
                    )));
                }
            }
        }

        let core = portable.target("CoveUIAgentCore")?;
        Self::require(
            core.dependency_count == 1 && core.products == BTreeSet::from(["CoveFileSystem".to_string()]),
            "Agent skills may use CoveFileSystem, but must not depend on UI or Engine domains",
        )?;
        Self::require(
            !portable.local_dependencies.contains(&self.path("Engine")),
            "CoveUI/DevTools/Inspection must not depend on Engine",
        )?;
        Self::require(
            !ui.local_dependencies.contains(&self.path("Editor")),
            "CoveUI must not depend on Editor",
        )?;
        let devtools = self
            .loader
            .manifest(&self.sdk_root.join("DevTools"), &BTreeMap::new())?
            .clone();
        Self::require(
            devtools.product_names.contains("CoveUIAgent"),
            "DevTools must vend the CoveUIAgent product",
        )?;

        self.check_sdk_independence(&ui)?;
        self.check_engine_independence()?;

        let capability = self
            .loader
            .manifest(&self.path("Engine"), &BTreeMap::new())?
            .clone()
            .target("CapabilityRuntime")?
            .clone();
        Self::require(
            capability.products == BTreeSet::from(["CoveUIInspection".to_string()]),
            "CapabilityRuntime must depend on exactly the CoveUIInspection product",
        )?;

        let workspace = self
            .loader
            .manifest(&self.path("."), &BTreeMap::new())?
            .clone();
        Self::require(
            workspace.local_dependencies == BTreeSet::from([self.path("Editor")]),
            "The workspace package must depend on Editor and nothing else",
        )?;
        Self::require(
            workspace.target_count == 1,
            "The workspace must not duplicate Editor's target graph",
        )?;

        self.check_android_applications()?;
        self.check_app_content()?;
        self.check_tooling()?;

        Terminal::info(SUCCESS);
        drop(guard);
        Ok(())
    }

    /// The SDK owns UI and the shared native layer. It must never reach back
    /// into the Studio package, and a plain UI application must not be able to
    /// pull scene, physics or render-backend modules through it.
    fn check_sdk_independence(&self, ui: &DumpPackage) -> Result<(), ToolError> {
        let engine_only: Vec<&str> = ENGINE_ONLY_PRODUCTS
            .iter()
            .copied()
            .filter(|product| ui.referenced_products().contains(*product))
            .collect();
        Self::require(
            engine_only.is_empty(),
            &format!(
                "CoveUI must not vend engine products: {}",
                engine_only.join(", ")
            ),
        )?;
        let studio = ["Engine", "Editor", "Platforms/Android"]
            .iter()
            .map(|relative| self.root.join(relative))
            .collect::<BTreeSet<_>>();
        let studio_dependency = ui
            .local_dependencies
            .iter()
            .find(|dependency| studio.contains(*dependency));
        Self::require(
            studio_dependency.is_none(),
            &format!(
                "CoveUI must not depend on a Studio package: {}",
                studio_dependency
                    .map(|path| path.display().to_string())
                    .unwrap_or_default()
            ),
        )
    }

    /// Scene and render modules live in Studio. They may consume the SDK's
    /// shared native layer, but never the Compose view tree or the window host.
    fn check_engine_independence(&mut self) -> Result<(), ToolError> {
        let engine_directory = self.path("Engine");
        let engine = self
            .loader
            .manifest(&engine_directory, &BTreeMap::new())?
            .clone();
        let leaked: Vec<&str> = UI_ONLY_PRODUCTS
            .iter()
            .copied()
            .filter(|product| engine.referenced_products().contains(*product))
            .collect();
        Self::require(
            leaked.is_empty(),
            &format!("Engine must not reach into the UI layer: {}", leaked.join(", ")),
        )
    }

    /// The Android package is dumped once per application configuration: content
    /// (UI) from a starter package, a game package, and its own showcase graph.
    fn check_android_applications(&mut self) -> Result<(), ToolError> {
        let android_directory = self.path("Platforms/Android");
        let starter = self.application.display().to_string();
        let content = self
            .loader
            .manifest(
                &android_directory,
                &BTreeMap::from([("COVE_ANDROID_UI_PACKAGE".to_string(), starter)]),
            )?
            .clone();
        let forbidden: BTreeSet<PathBuf> = BTreeSet::from([
            self.path("Editor"),
            self.sdk_root.join("Examples"),
            self.sdk_root.join("Examples/Counter"),
        ]);
        let pulled: Vec<String> = forbidden
            .intersection(&content.local_dependencies)
            .map(|path| path.display().to_string())
            .collect();
        Self::require(
            pulled.is_empty(),
            &format!(
                "An Android application built from the generated application must not depend on {}",
                pulled.join(", ")
            ),
        )?;

        let game_directory = std::env::temp_dir().join(format!(
            "cove-game-contract-{}",
            std::process::id()
        ));
        files::directory(&game_directory)
            .map_err(|error| ToolError::message(error.to_string()))?;
        let game_guard = TempGuard(game_directory.clone());
        let game = self
            .loader
            .manifest(
                &android_directory,
                &BTreeMap::from([(
                    "COVE_ANDROID_GAME_PACKAGE".to_string(),
                    game_directory.display().to_string(),
                )]),
            )?
            .clone();
        Self::require(
            game.local_dependencies.contains(&self.path("Editor")),
            "An Android game application must depend on Editor",
        )?;
        Self::require(
            !game.local_dependencies.contains(&self.sdk_root.join("Examples")),
            "An Android game application must not depend on CoveUI/Examples",
        )?;

        let showcase = self
            .loader
            .manifest(&android_directory, &BTreeMap::new())?
            .clone();
        Self::require(
            showcase
                .local_dependencies
                .contains(&self.sdk_root.join("Examples")),
            "The Android showcase must depend on CoveUI/Examples",
        )?;
        Self::require(
            !showcase.local_dependencies.contains(&self.path("Editor")),
            "The Android showcase must not depend on Editor",
        )?;
        drop(game_guard);
        Ok(())
    }

    /// The Studio example and SDK template present the UI module directly; both
    /// AppContent entry points must call the same factory.
    fn check_app_content(&self) -> Result<(), ToolError> {
        for file in [
            self.application.join("Sources/AppContent/App.swift"),
            self.sdk_root
                .join("Tools/Cove/Sources/CoveCLI/Templates/UI/Sources/AppContent/App.swift"),
        ] {
            let content = self.text(&file)?;
            Self::require(
                content.contains("import CoveUI\n"),
                &format!("{} must import CoveUI", file.display()),
            )?;
            Self::require(
                !content.contains("import NativeRHI") && !content.contains("import CoveUIRuntime"),
                &format!("{} must not import NativeRHI or CoveUIRuntime", file.display()),
            )?;
            Self::require(
                content.contains("makeApplicationContent()"),
                &format!("{} must call makeApplicationContent()", file.display()),
            )?;
        }
        Ok(())
    }

    /// The CLI ships with the SDK, owns no Android side copy, and the starter's
    /// configuration and resources describe those real package names.
    fn check_tooling(&mut self) -> Result<(), ToolError> {
        let developer_directory = self.path("Tools/Developer");
        let developer = self
            .loader
            .manifest(&developer_directory, &BTreeMap::new())?
            .clone();
        Self::require(
            developer.product_names == BTreeSet::from(["cove-dev".to_string()]),
            "Tools/Developer must vend only the cove-dev executable",
        )?;
        let example = self.application.clone();
        let tools = self
            .loader
            .manifest(&self.sdk_root.join("Tools/Cove"), &BTreeMap::new())?
            .clone();
        Self::require(
            tools.product_names == BTreeSet::from(["cove".to_string()]),
            "CoveUI/Tools/Cove must vend exactly the cove product",
        )?;
        let allowed: BTreeSet<PathBuf> = BTreeSet::from([
            self.sdk_root.join("Tools/Support"),
            self.sdk_root.join("System"),
        ]);
        let unexpected: Vec<String> = developer
            .local_dependencies
            .difference(&allowed)
            .map(|path| path.display().to_string())
            .collect();
        Self::require(
            unexpected.is_empty(),
            &format!(
                "Repository tools must build independently of application and engine packages: {}",
                unexpected.join(", ")
            ),
        )?;
        let expected_tools: BTreeSet<PathBuf> = BTreeSet::from([
            self.sdk_root.join("Hosts/Android/Contract"),
            self.sdk_root.join("DevTools/Protocol"),
            self.sdk_root.join("Logging"),
            self.sdk_root.join("Tools/Support"),
            self.sdk_root.join("System"),
        ]);
        Self::require(
            tools.local_dependencies == expected_tools,
            &format!(
                "The shipped CLI must depend only on SDK packages: {}",
                tools
                    .local_dependencies
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        )?;
        Self::require(
            !self.root.join("Platforms/Android/Tools").exists(),
            "Android must not own a separate developer CLI",
        )?;
        Self::require(
            !example.join("android.swift").exists(),
            "the generated application must not ship its own android.swift launcher",
        )?;
        Self::require(
            !example.join("cove-android.json").exists(),
            "the generated application must not ship a separate cove-android.json",
        )?;
        self.check_configuration(&example)?;
        Self::require(
            !example.join("Sources/DesktopApp").exists(),
            "the generated application must not ship a DesktopApp outside AppContent",
        )?;

        let starter = self
            .loader
            .manifest(&example.clone(), &BTreeMap::new())?
            .clone();
        Self::require(
            starter.product_names == BTreeSet::from(["AppContent".to_string()]),
            "the generated application must vend exactly the AppContent product",
        )?;
        let resources = self.text(&example.join("Sources/AppContent/AppResources.swift"))?;
        Self::require(
            resources.contains(&format!("{}_AppContent", starter.name)),
            "Resource lookup must match the actual SwiftPM package and target",
        )
    }

    fn check_configuration(&self, example: &Path) -> Result<(), ToolError> {
        let content = self.text(&example.join("cove.json"))?;
        let configuration: Value = serde_json::from_str(&content).map_err(|_| {
            ToolError::message("the generated application/cove.json is not a JSON object")
        })?;
        if !configuration.is_object() {
            return Err(ToolError::message(
                "the generated application/cove.json is not a JSON object",
            ));
        }
        let platforms: BTreeSet<String> = configuration
            .get("targets")
            .and_then(|targets| targets.get("platforms"))
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let expected: BTreeSet<String> =
            SUPPORTED_PLATFORMS.iter().map(|value| (*value).to_string()).collect();
        Self::require(
            platforms == expected,
            &format!(
                "cove.json must target {}",
                SUPPORTED_PLATFORMS.join(", ")
            ),
        )?;
        let sdk_version = configuration
            .get("toolchain")
            .and_then(|toolchain| toolchain.get("sdkVersion"))
            .and_then(Value::as_str)
            .ok_or_else(|| {
                ToolError::message(
                    "the generated application/cove.json must declare toolchain.sdkVersion",
                )
            })?;
        Self::require(
            !sdk_version.is_empty(),
            "cove.json toolchain.sdkVersion must name a released SDK version",
        )
    }

    fn path(&self, relative: &str) -> PathBuf {
        canonical_path(relative, &self.root)
    }

    /// `Path.read_text()` applies universal newline translation; keep the port
    /// faithful.
    fn text(&self, url: &Path) -> Result<String, ToolError> {
        let content = files::text(url).map_err(|error| {
            ToolError::message(format!("Cannot read {}: {error}", url.display()))
        })?;
        Ok(content.replace("\r\n", "\n").replace('\r', "\n"))
    }

    fn require(condition: bool, message: &str) -> Result<(), ToolError> {
        if condition {
            Ok(())
        } else {
            Err(ToolError::message(message))
        }
    }
}

/// Removes a temporary directory on every exit path.
struct TempGuard(PathBuf);

impl Drop for TempGuard {
    fn drop(&mut self) {
        let _ = files::remove(&self.0);
    }
}

/// Keeps the platform list reachable for tests.
pub fn supported_platforms() -> BTreeSet<String> {
    SUPPORTED_PLATFORMS.iter().map(|value| (*value).to_string()).collect()
}

/// Keeps `repository` reachable for the module's public surface.
pub fn checkout_root() -> PathBuf {
    repository::root()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn product_sets_are_disjoint_by_layer() {
        let demo: BTreeSet<&str> = DEMO_PRODUCTS.into_iter().collect();
        let engine: BTreeSet<&str> = ENGINE_ONLY_PRODUCTS.into_iter().collect();
        let ui: BTreeSet<&str> = UI_ONLY_PRODUCTS.into_iter().collect();
        assert!(demo.is_disjoint(&engine));
        assert!(demo.is_disjoint(&ui));
        assert!(engine.is_disjoint(&ui));
        assert!(ui.contains("CoveUI"));
        assert!(engine.contains("RenderBackend"));
    }

    #[test]
    fn the_supported_platform_list_matches_cove_json() {
        assert_eq!(
            supported_platforms(),
            ["mac", "win", "linux", "android", "ios"]
                .into_iter()
                .map(str::to_string)
                .collect()
        );
    }

    #[test]
    fn the_sdk_root_defaults_to_the_cove_ui_symlink() {
        let checks = BoundaryChecks::new(Path::new("/tmp/cove-root"), &BTreeMap::new());
        assert!(checks.sdk_root.ends_with("CoveUI"));
        let overridden = BoundaryChecks::new(
            Path::new("/tmp/cove-root"),
            &BTreeMap::from([("COVE_SDK_ROOT".to_string(), "/elsewhere/sdk".to_string())]),
        );
        assert_eq!(overridden.sdk_root, PathBuf::from("/elsewhere/sdk"));
    }

    #[test]
    fn the_checkout_root_helper_resolves() {
        assert!(checkout_root().is_absolute());
    }
}
