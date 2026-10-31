//! The input records the step protocol and the document formatter receive.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Processes/Inputs.swift`.

use crate::contract::plugin_contract::{PluginInputField, PluginInputType};

/// `record { request: string, stdout: string }`: the step request as JSON and a
/// window of the last command's output, the input of every entry point the step
/// protocol drives.
pub fn step_input_type() -> PluginInputType {
    PluginInputType::Record(vec![
        PluginInputField::new("request", PluginInputType::String),
        PluginInputField::new("stdout", PluginInputType::String),
    ])
}

/// `record { text: string }`: the whole document handed to a format entry point.
pub fn document_format_input_type() -> PluginInputType {
    PluginInputType::Record(vec![PluginInputField::new("text", PluginInputType::String)])
}
