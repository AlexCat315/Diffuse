//! Translation of
//! Editor/Sources/EditorUI/Panels/ScriptEditor/GutterLabels.swift.

use cove_ui_compose::primitives::text::code::folding_options::TextFoldingLabels;
use cove_ui_compose::primitives::text::code::gutter_options::{
    TextBreakpointState, TextGutterLabels,
};

use crate::localization::localized;

pub fn script_gutter_labels() -> TextGutterLabels {
    TextGutterLabels {
        line_actions: Box::new(|line| percent_d(&localized("Line %d actions"), line + 1)),
        add_breakpoint: Box::new(|line| {
            percent_d(&localized("Add breakpoint at line %d"), line + 1)
        }),
        remove_breakpoint: Box::new(|line| {
            percent_d(&localized("Remove breakpoint at line %d"), line + 1)
        }),
        enable_breakpoint: Box::new(|line| {
            percent_d(&localized("Enable breakpoint at line %d"), line + 1)
        }),
        disable_breakpoint: Box::new(|line| {
            percent_d(&localized("Disable breakpoint at line %d"), line + 1)
        }),
        execution: Box::new(|line| percent_d(&localized("Execution paused at line %d"), line + 1)),
        breakpoint_state: Box::new(|state| match state {
            TextBreakpointState::Enabled => localized("Enabled breakpoint"),
            TextBreakpointState::Disabled => localized("Disabled breakpoint"),
            TextBreakpointState::Unverified => localized("Unverified breakpoint"),
        }),
    }
}

pub fn script_folding_labels() -> TextFoldingLabels {
    TextFoldingLabels {
        collapse: Box::new(|line| percent_d(&localized("Collapse code at line %d"), line + 1)),
        expand: Box::new(|line| percent_d(&localized("Expand code at line %d"), line + 1)),
        summary: Box::new(|count| percent_d(&localized("%d folded lines"), count)),
        hidden_breakpoints: Box::new(|count| {
            percent_d(&localized("%d breakpoints in folded code"), count)
        }),
    }
}

/// Swift's `String(format: "... %d ...", value)` for a single integer argument.
fn percent_d(template: &str, value: usize) -> String {
    template.replacen("%d", &value.to_string(), 1)
}
