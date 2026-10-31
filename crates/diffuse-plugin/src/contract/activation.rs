//! Activation event names a package may declare.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/Activation.swift`.

use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_segmentation::UnicodeSegmentation;

pub enum PluginActivationEvent {}

impl PluginActivationEvent {
    const PREFIXES: [&'static str; 9] = [
        "onLanguage",
        "onCommand",
        "onView",
        "onAIProvider",
        "onAgent",
        "onAITool",
        "onWorkspaceContains",
        "onURI",
        "onService",
    ];

    pub fn is_valid(value: &str) -> bool {
        if value == "onStartup" || value == "onAIChat" {
            return true;
        }
        // Swift: `value.split(separator: ":", maxSplits: 1,
        // omittingEmptySubsequences: false)` — at most two fields, empty fields
        // kept.
        let mut parts = value.splitn(2, ':');
        let head = parts.next().unwrap_or_default();
        let Some(tail) = parts.next() else {
            return false;
        };
        !tail.is_empty()
            && tail.graphemes(true).count() <= 256
            && Self::PREFIXES.contains(&head)
            // `CharacterSet.controlCharacters` is Unicode categories Cc and Cf.
            && !value.chars().any(|character| {
                matches!(
                    get_general_category(character),
                    GeneralCategory::Control | GeneralCategory::Format
                )
            })
    }
}
