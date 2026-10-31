//! Generates the exported gameplay SwiftPM package from a project's static
//! script index.

use crate::support::files;
use crate::support::terminal::ToolError;
use serde::Deserialize;
use std::path::Path;

#[derive(Deserialize)]
struct Index {
    entries: Vec<Entry>,
}

#[derive(Deserialize)]
struct Entry {
    source: String,
    identifier: String,
}

pub struct GameplayPackage;

impl GameplayPackage {
    pub fn create(project: &Path, destination: &Path, root: &Path) -> Result<usize, ToolError> {
        files::reset(destination).map_err(io_error)?;
        let index_url = project.join(".cove/static-scripts.json");
        let entries: Vec<Entry> = if index_url.exists() {
            let data = files::read(&index_url).map_err(io_error)?;
            serde_json::from_slice::<Index>(&data)
                .map_err(|error| {
                    ToolError::message(format!(
                        "Cannot decode {}: {error}",
                        index_url.display()
                    ))
                })?
                .entries
        } else {
            Vec::new()
        };
        let products = ["EngineKernel", "SceneRuntime", "ScriptRuntime", "SIMDCompat"];
        let dependencies = products
            .iter()
            .map(|product| format!(".product(name: \"{product}\", package: \"Engine\")"))
            .collect::<Vec<_>>()
            .join(", ");
        let mut targets: Vec<String> = Vec::new();
        let mut imports: Vec<String> = Vec::new();
        let mut registrations: Vec<String> = Vec::new();
        let standardized_project = standardized(project);
        for (number, entry) in entries.iter().enumerate() {
            let module = format!("ProjectScript{number}");
            let source = destination.join("Sources").join(&module);
            let file = standardized(&project.join(&entry.source));
            if !file.starts_with(&standardized_project) {
                return Err(ToolError::message(format!(
                    "Script source escapes exported project: {}",
                    entry.source
                )));
            }
            files::copy(&file, &source.join("GameScript.swift")).map_err(io_error)?;
            files::write_text(
                &format!(
                    "import ScriptRuntime\npublic func registerProjectScript(into runtime: ScriptRuntime) {{\n    runtime.register(behavior: GameScript.self, named: {})\n}}\n\n",
                    literal(&entry.identifier)
                ),
                &source.join("Registration.swift"),
            )
            .map_err(io_error)?;
            targets.push(format!(
                ".target(name: \"{module}\", dependencies: [{dependencies}])"
            ));
            imports.push(format!("import {module}"));
            registrations.push(format!(
                "        {module}.registerProjectScript(into: runtime)"
            ));
        }
        let registry = format!(
            "import ScriptRuntime\n{}\npublic enum ProjectGameplay {{\n    public static func register(into runtime: ScriptRuntime) -> Int {{\n{}\n        return {}\n    }}\n}}\n",
            imports.join("\n"),
            registrations.join("\n"),
            entries.len()
        );
        files::write_text(
            &registry,
            &destination.join("Sources/CoveAndroidGameplay/Registry.swift"),
        )
        .map_err(io_error)?;
        let mut aggregate: Vec<String> =
            vec![".product(name: \"ScriptRuntime\", package: \"Engine\")".to_string()];
        aggregate.extend((0..entries.len()).map(|index| format!("\"ProjectScript{index}\"")));
        targets.push(format!(
            ".target(name: \"CoveAndroidGameplay\", dependencies: [{}])",
            aggregate.join(", ")
        ));
        files::write_text(
            &format!(
                "// swift-tools-version: 6.4\nimport PackageDescription\nlet package = Package(\n    name: \"CoveAndroidGameplay\",\n    platforms: [.macOS(.v26), .iOS(.v26)],\n    products: [.library(name: \"CoveAndroidGameplay\", targets: [\"CoveAndroidGameplay\"])],\n    dependencies: [.package(path: {})],\n    targets: [{}]\n)\n\n",
                literal(&root.join("Engine").display().to_string()),
                targets.join(",\n        ")
            ),
            &destination.join("Package.swift"),
        )
        .map_err(io_error)?;
        Ok(entries.len())
    }
}

fn standardized(path: &Path) -> std::path::PathBuf {
    crate::support::repository::standardized(path)
}

/// Swift accepts JSON's usual escapes but uses `\u{...}` for control scalars.
fn literal(value: &str) -> String {
    let mut result = String::from("\"");
    for scalar in value.chars() {
        match scalar {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            other if (other as u32) <= 31 || (other as u32) == 127 => {
                result.push_str(&format!("\\u{{{:x}}}", other as u32));
            }
            other => result.push(other),
        }
    }
    result.push('"');
    result
}

fn io_error(error: std::io::Error) -> ToolError {
    ToolError::message(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literals_escape_quotes_backslashes_and_control_scalars() {
        assert_eq!(literal("plain"), "\"plain\"");
        assert_eq!(literal("a\"b"), "\"a\\\"b\"");
        assert_eq!(literal("a\\b"), "\"a\\\\b\"");
        assert_eq!(literal("a\u{1}b"), "\"a\\u{1}b\"");
        assert_eq!(literal("你好"), "\"你好\"");
    }

    #[test]
    fn an_empty_project_still_writes_a_valid_package() {
        let root = crate::validation::runtime::support::temp::directory("cove-gameplay-").unwrap();
        let project = root.join("project");
        let destination = root.join("gameplay");
        std::fs::create_dir_all(&project).unwrap();
        let count = GameplayPackage::create(&project, &destination, &root).unwrap();
        assert_eq!(count, 0);
        let package = std::fs::read_to_string(destination.join("Package.swift")).unwrap();
        assert!(package.contains("name: \"CoveAndroidGameplay\""));
        assert!(package.contains("targets: [.target(name: \"CoveAndroidGameplay\""));
        let registry =
            std::fs::read_to_string(destination.join("Sources/CoveAndroidGameplay/Registry.swift"))
                .unwrap();
        assert!(registry.contains("return 0"));
        let _ = files::remove(&root);
    }

    #[test]
    fn a_script_that_escapes_the_project_is_rejected() {
        let root = crate::validation::runtime::support::temp::directory("cove-gameplay-").unwrap();
        let project = root.join("project");
        std::fs::create_dir_all(project.join(".cove")).unwrap();
        std::fs::write(
            project.join(".cove/static-scripts.json"),
            br#"{"entries":[{"source":"../../etc/passwd","identifier":"Escape"}]}"#,
        )
        .unwrap();
        let error = GameplayPackage::create(&project, &root.join("out"), &root).unwrap_err();
        assert!(error.to_string().contains("escapes exported project"), "{error}");
        let _ = files::remove(&root);
    }

    #[test]
    fn each_entry_becomes_its_own_target_and_registration() {
        let root = crate::validation::runtime::support::temp::directory("cove-gameplay-").unwrap();
        let project = root.join("project");
        std::fs::create_dir_all(project.join(".cove")).unwrap();
        std::fs::create_dir_all(project.join("Scripts")).unwrap();
        std::fs::write(project.join("Scripts/Game.swift"), "// game").unwrap();
        std::fs::write(
            project.join(".cove/static-scripts.json"),
            br#"{"entries":[{"source":"Scripts/Game.swift","identifier":"Game"}]}"#,
        )
        .unwrap();
        let destination = root.join("out");
        let count = GameplayPackage::create(&project, &destination, &root).unwrap();
        assert_eq!(count, 1);
        let package = std::fs::read_to_string(destination.join("Package.swift")).unwrap();
        assert!(package.contains(".target(name: \"ProjectScript0\""));
        assert!(package.contains("name: \"CoveAndroidGameplay\""));
        let registration =
            std::fs::read_to_string(destination.join("Sources/ProjectScript0/Registration.swift"))
                .unwrap();
        assert!(registration.contains("named: \"Game\""));
        let _ = files::remove(&root);
    }
}
