//! Canonicalises manifest paths and narrows one `swift package dump-package`
//! result to the fields the boundary checks assert on.

use crate::support::shell;
use crate::support::terminal::ToolError;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// Canonicalises a manifest path the way `Path(...).resolve()` did: absolute,
/// free of `.`/`..` components and with symlinks resolved.
pub fn canonical_path(path: &str, relative_to: &Path) -> PathBuf {
    let candidate = if Path::new(path).is_absolute() {
        PathBuf::from(path)
    } else {
        relative_to.join(path)
    };
    let standardized = crate::support::repository::standardized(&candidate);
    std::fs::canonicalize(&standardized).unwrap_or(standardized)
}

/// A declared target, with its dependencies split by manifest shape.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub name: String,
    pub dependency_count: usize,
    pub by_name: BTreeSet<String>,
    pub products: BTreeSet<String>,
}

impl Target {
    pub fn new(object: &Value) -> Result<Self, ToolError> {
        let name = object
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                ToolError::message("A target entry in the dumped package manifest has no name")
            })?
            .to_string();
        let dependencies = object
            .get("dependencies")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let by_name = dependencies
            .iter()
            .filter_map(|dependency| Self::value(dependency, "byName"))
            .collect();
        let products = dependencies
            .iter()
            .filter_map(|dependency| Self::value(dependency, "product"))
            .collect();
        Ok(Self {
            name,
            dependency_count: dependencies.len(),
            by_name,
            products,
        })
    }

    /// `item["byName"][0]` / `item["product"][0]`, which always carry the value.
    fn value(dependency: &Value, key: &str) -> Option<String> {
        dependency
            .get(key)
            .and_then(Value::as_array)
            .and_then(|values| values.first())
            .and_then(Value::as_str)
            .map(str::to_string)
    }
}

/// One `swift package dump-package` result, narrowed to the fields the boundary
/// checks assert on.
#[derive(Clone, Debug)]
pub struct DumpPackage {
    pub directory: PathBuf,
    pub name: String,
    pub product_names: BTreeSet<String>,
    pub target_count: usize,
    /// Local (file system) dependencies, resolved against the checkout root.
    pub local_dependencies: BTreeSet<PathBuf>,
    targets: BTreeMap<String, Target>,
}

impl DumpPackage {
    pub fn new(directory: &Path, root: &Path, json: &Value) -> Result<Self, ToolError> {
        let name = json
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                ToolError::message(format!(
                    "{} did not dump a package name; expected `swift package dump-package` JSON",
                    directory.display()
                ))
            })?
            .to_string();
        let product_names: BTreeSet<String> = json
            .get("products")
            .and_then(Value::as_array)
            .map(|products| {
                products
                    .iter()
                    .filter_map(|product| product.get("name").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let entries = json
            .get("targets")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let target_count = entries.len();
        let mut targets: BTreeMap<String, Target> = BTreeMap::new();
        for entry in &entries {
            let Some(object) = entry.as_object() else {
                continue;
            };
            let target = Target::new(entry)?;
            targets.insert(target.name.clone(), target);
            let _ = object;
        }
        let mut local_dependencies: BTreeSet<PathBuf> = BTreeSet::new();
        let dependencies = json
            .get("dependencies")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for entry in &dependencies {
            let path = entry
                .get("fileSystem")
                .and_then(Value::as_array)
                .and_then(|values| values.first())
                .and_then(|location| location.get("path"))
                .and_then(Value::as_str);
            if let Some(path) = path {
                local_dependencies.insert(canonical_path(path, root));
            }
        }
        Ok(Self {
            directory: directory.to_path_buf(),
            name,
            product_names,
            target_count,
            local_dependencies,
            targets,
        })
    }

    pub fn target(&self, name: &str) -> Result<&Target, ToolError> {
        self.targets.get(name).ok_or_else(|| {
            ToolError::message(format!(
                "Package {} declares no target named {name}",
                self.name
            ))
        })
    }

    pub fn all_targets(&self) -> Vec<&Target> {
        self.targets.values().collect()
    }

    /// Products this package's targets pull from other packages by name.
    pub fn referenced_products(&self) -> BTreeSet<String> {
        self.targets
            .values()
            .flat_map(|target| target.products.iter().cloned())
            .collect()
    }
}

/// Runs `swift package dump-package` for a package in the checkout. The Android
/// override variables are stripped from the inherited environment and applied
/// only by the checks that configure an application.
pub struct ManifestLoader {
    root: PathBuf,
    executable: String,
    environment: BTreeMap<String, String>,
    cache: BTreeMap<String, DumpPackage>,
}

impl ManifestLoader {
    pub const ANDROID_OVERRIDES: [&'static str; 2] =
        ["COVE_ANDROID_UI_PACKAGE", "COVE_ANDROID_GAME_PACKAGE"];

    pub fn new(root: &Path, environment: &BTreeMap<String, String>) -> Self {
        let mut environment = environment.clone();
        for key in Self::ANDROID_OVERRIDES {
            environment.remove(key);
        }
        let executable = environment
            .get("COVE_SWIFT_EXECUTABLE")
            .cloned()
            .unwrap_or_else(|| "swift".to_string());
        Self {
            root: root.to_path_buf(),
            executable,
            environment,
            cache: BTreeMap::new(),
        }
    }

    pub fn manifest(
        &mut self,
        location: &Path,
        overrides: &BTreeMap<String, String>,
    ) -> Result<&DumpPackage, ToolError> {
        let directory = crate::support::repository::standardized(location);
        let mut key_parts: Vec<String> = vec![directory.display().to_string()];
        key_parts.extend(
            overrides
                .iter()
                .map(|(name, value)| format!("{name}={value}")),
        );
        let key = key_parts.join("\u{0}");
        if !self.cache.contains_key(&key) {
            let mut environment = self.environment.clone();
            for (name, value) in overrides {
                environment.insert(name.clone(), value.clone());
            }
            let output = shell::output(
                &[
                    self.executable.clone(),
                    "package".into(),
                    "--package-path".into(),
                    directory.display().to_string(),
                    "dump-package".into(),
                ],
                None,
                &environment,
                false,
            )?;
            let json = decode(&output, &directory.display().to_string())?;
            let package = DumpPackage::new(&directory, &self.root, &json)?;
            self.cache.insert(key.clone(), package);
        }
        Ok(self.cache.get(&key).expect("just inserted"))
    }
}

fn decode(output: &str, path: &str) -> Result<Value, ToolError> {
    if let Ok(json) = serde_json::from_str::<Value>(output)
        && json.is_object()
    {
        return Ok(json);
    }
    // Progress and diagnostics share the captured stream, so fall back to the
    // outermost JSON object when the output is not pure JSON.
    if let (Some(start), Some(end)) = (output.find('{'), output.rfind('}'))
        && start < end
        && let Ok(json) = serde_json::from_str::<Value>(&output[start..=end])
        && json.is_object()
    {
        return Ok(json);
    }
    Err(ToolError::message(format!(
        "swift package dump-package for {path} did not produce JSON"
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn root() -> PathBuf {
        PathBuf::from("/tmp/cove-boundary-root")
    }

    fn manifest() -> Value {
        json!({
            "name": "Fixture",
            "products": [{"name": "CoveUI"}, {"name": "AppContent"}],
            "targets": [
                {
                    "name": "CoveUI",
                    "dependencies": [
                        {"byName": ["CoveUIWorkspace"]},
                        {"product": ["CoveFileSystem", "System"]}
                    ]
                },
                {"name": "Other", "dependencies": []}
            ],
            "dependencies": [
                {"fileSystem": [{"path": "Editor"}]},
                {"fileSystem": [{"path": "/abs/Examples"}]},
                {"registry": []}
            ]
        })
    }

    #[test]
    fn the_dump_is_narrowed_to_the_asserted_fields() {
        let package = DumpPackage::new(Path::new("/tmp/fixture"), &root(), &manifest()).unwrap();
        assert_eq!(package.name, "Fixture");
        assert_eq!(package.target_count, 2);
        assert!(package.product_names.contains("CoveUI"));
        let target = package.target("CoveUI").unwrap();
        assert_eq!(target.dependency_count, 2);
        assert!(target.by_name.contains("CoveUIWorkspace"));
        assert!(target.products.contains("CoveFileSystem"));
        // `value(_:_:)` reads `item["product"][0]` only, so the second element
        // of the fixture's product list is deliberately not referenced — the
        // Swift original has the same narrowing.
        assert_eq!(
            package.referenced_products(),
            ["CoveFileSystem".to_string()].into_iter().collect()
        );
    }

    #[test]
    fn local_dependencies_are_canonicalised_against_the_root() {
        let package = DumpPackage::new(Path::new("/tmp/fixture"), &root(), &manifest()).unwrap();
        assert!(package.local_dependencies.contains(&root().join("Editor")));
        assert!(
            package
                .local_dependencies
                .contains(&PathBuf::from("/abs/Examples"))
        );
        assert_eq!(package.local_dependencies.len(), 2);
    }

    #[test]
    fn a_missing_package_name_is_reported() {
        let error = DumpPackage::new(Path::new("/tmp/fixture"), &root(), &json!({})).unwrap_err();
        assert!(error.to_string().contains("did not dump a package name"));
    }

    #[test]
    fn an_unknown_target_names_the_package() {
        let package = DumpPackage::new(Path::new("/tmp/fixture"), &root(), &manifest()).unwrap();
        let error = package.target("Absent").unwrap_err();
        assert_eq!(error.to_string(), "Package Fixture declares no target named Absent");
    }

    #[test]
    fn decoding_falls_back_to_the_outermost_object() {
        let document = decode("building...\n{\"name\": \"X\"}\ntrailing\n", "/tmp/x").unwrap();
        assert_eq!(document["name"], json!("X"));
        assert!(decode("no json here", "/tmp/x").is_err());
    }

    // Swift: testAbsoluteSDKPathDoesNotAcquireTheStudioPrefix.
    #[test]
    fn an_absolute_path_does_not_acquire_the_studio_prefix() {
        let sdk = std::env::current_dir().unwrap();
        let studio = std::env::temp_dir().join("studio");
        assert_eq!(
            canonical_path(&sdk.display().to_string(), &studio),
            std::fs::canonicalize(&sdk).unwrap()
        );
    }

    #[test]
    fn relative_paths_join_the_base() {
        let base = std::env::temp_dir();
        let path = canonical_path("cove-boundary-fixture", &base);
        assert!(path.starts_with(&base));
    }

    #[test]
    fn the_loader_strips_android_overrides_from_the_environment() {
        let environment = BTreeMap::from([
            ("COVE_ANDROID_UI_PACKAGE".to_string(), "/starter".to_string()),
            ("COVE_SWIFT_EXECUTABLE".to_string(), "swift".to_string()),
        ]);
        let loader = ManifestLoader::new(&root(), &environment);
        assert!(!loader.environment.contains_key("COVE_ANDROID_UI_PACKAGE"));
        assert!(loader.environment.contains_key("COVE_SWIFT_EXECUTABLE"));
    }
}
