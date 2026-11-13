//! Translation of `Editor/Sources/EditorCore/Workstation/AgentTools.swift`.
//!
//! The `list_files`/`read_file`/`write_file` and media project tools, over the
//! same workstation the UI drives.

use std::path::PathBuf;

use diffuse_kernel::codable::new_uuid;
use diffuse_media::MediaUrl;
use diffuse_media::editing::tools::FFmpegTools;
use serde_json::{Value, json};

use crate::ai::editor_project_tools::EditorProjectToolError;
use crate::application::editor_application::EditorApplication;

impl EditorApplication {
    pub(crate) fn execute_workstation_tool(
        &self,
        name: &str,
        arguments: &serde_json::Map<String, Value>,
    ) -> Result<Option<Value>, EditorProjectToolError> {
        match name {
            "list_files" => Ok(Some(json!({
                "files": self.workstation.documents.files(),
            }))),
            "read_file" => {
                let path = required_string(arguments, "path");
                let document = self
                    .workstation
                    .documents
                    .read(path)
                    .map_err(|error| EditorProjectToolError::new(error.error_description()))?;
                Ok(Some(json!({
                    "path": document.path,
                    "text": document.text,
                    "exists": document.exists_on_disk(),
                    "dirty": document.is_dirty(),
                })))
            }
            "write_file" => {
                let path = required_string(arguments, "path");
                let text = required_string(arguments, "text");
                let expected = arguments
                    .get("expected_text")
                    .and_then(Value::as_str);
                self.workstation
                    .documents
                    .write(path, text, expected)
                    .map_err(|error| EditorProjectToolError::new(error.error_description()))?;
                Ok(Some(json!({ "ok": true })))
            }
            "get_media_timeline" => Ok(serde_json::to_value(self.workstation.media.composition()).ok()),
            "add_media_clip" => {
                let path = required_string(arguments, "path");
                self.workstation
                    .media
                    .add(path)
                    .map_err(|error| EditorProjectToolError::new(error.error_description().to_string()))?;
                Ok(Some(json!({ "ok": true })))
            }
            "trim_media_clip" => {
                let index = required_integer(arguments, "index") as usize;
                let start = required_number(arguments, "start");
                let duration = required_number(arguments, "duration");
                self.workstation
                    .media
                    .trim(index, start, duration)
                    .map_err(|error| EditorProjectToolError::new(error.error_description().to_string()))?;
                Ok(Some(json!({ "ok": true })))
            }
            "remove_media_clip" => {
                let index = required_integer(arguments, "index") as usize;
                self.workstation.media.remove(index);
                Ok(Some(json!({ "ok": true })))
            }
            "save_media_timeline" => {
                if !self.workstation.media.save() {
                    return Err(EditorProjectToolError::new(
                        self.workstation
                            .media
                            .error()
                            .unwrap_or_else(|| "Media save failed".to_string()),
                    ));
                }
                Ok(Some(json!({ "ok": true })))
            }
            "export_media" => {
                let directory = PathBuf::from(&self.project_directory).join("Exports");
                std::fs::create_dir_all(&directory)
                    .map_err(|error| EditorProjectToolError::new(error.to_string()))?;
                let output = directory.join(format!("video-{}.mp4", new_uuid()));
                let executable = FFmpegTools::executable().map_err(|error| {
                    EditorProjectToolError::new(error.error_description().to_string())
                })?;
                self.workstation
                    .media
                    .export(
                        &MediaUrl::from_file_path(output.to_string_lossy()),
                        &executable,
                    )
                    .map_err(|error| {
                        EditorProjectToolError::new(error.error_description().to_string())
                    })?;
                Ok(Some(json!({
                    "ok": true,
                    "output": output.to_string_lossy(),
                })))
            }
            _ => Ok(None),
        }
    }
}

/// Swift's `arguments["…"] as! String`: the tool schema validated the input
/// before dispatch, so a missing key traps like the forced cast.
fn required_string<'a>(arguments: &'a serde_json::Map<String, Value>, key: &str) -> &'a str {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .expect("the tool schema requires a string argument")
}

fn required_integer(arguments: &serde_json::Map<String, Value>, key: &str) -> i64 {
    arguments
        .get(key)
        .and_then(Value::as_i64)
        .expect("the tool schema requires an integer argument")
}

fn required_number(arguments: &serde_json::Map<String, Value>, key: &str) -> f64 {
    arguments
        .get(key)
        .and_then(Value::as_f64)
        .expect("the tool schema requires a number argument")
}
