//! `Editor/Sources/EditorUI/Panels/ScriptEditor/Diagnostics/CompletionConversion.swift`.
//!
//! The language server's completion items, converted into the list the text
//! field draws, and the cache that lets a highlighted row fetch documentation
//! the list itself left out.
//!
//! Difference from Swift: the resolution round trip was an `async` call made
//! from a `Task`; with no async runtime `resolve_completion` is synchronous, so
//! the resolver answers on the calling thread. Its signature keeps the
//! `Box<dyn FnOnce>` reply so the text field's contract is unchanged.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use cove_ui_compose::primitives::text::text_completion_rebase::{
    TextCompletionEdit, TextCompletionItem, TextCompletionRequest, TextCompletionResolver,
    TextInsertFormat,
};
use diffuse_editor_core::scripting::dynamic::dynamic_script_manager::DynamicScriptManager;
use diffuse_editor_core::scripting::rust_analyzer::language::script_language_models::{
    ScriptCompletionItem, ScriptCompletionResult,
};
use diffuse_editor_core::scripting::rust_analyzer::language::script_language_position::{
    ScriptLanguageSpan, ScriptSourceCoordinates,
};

pub struct ScriptCompletionConversion;

impl ScriptCompletionConversion {
    /// Server items become list rows: sorted the way the server orders them
    /// (by `sortText`, so popups group by kind), with every span converted from
    /// source offsets into buffer character indices.
    pub fn items(
        result: &ScriptCompletionResult,
        request: &TextCompletionRequest,
    ) -> Vec<TextCompletionItem> {
        let range = |span: ScriptLanguageSpan| -> std::ops::Range<usize> {
            let start = ScriptSourceCoordinates::character_index(&request.buffer, span.start);
            let end = ScriptSourceCoordinates::character_index(&request.buffer, span.end);
            start..start.max(end)
        };
        let mut sorted = result.items.clone();
        sorted.sort_by(|left, right| {
            let left = left.sort_text.clone().unwrap_or_else(|| left.label.clone());
            let right = right
                .sort_text
                .clone()
                .unwrap_or_else(|| right.label.clone());
            left.cmp(&right)
        });
        sorted
            .into_iter()
            .map(|source| {
                let mut item = TextCompletionItem::new(
                    source.id(),
                    source.label.clone(),
                    source.insert_text.clone(),
                );
                item.insert_text_format = if source.uses_snippet {
                    TextInsertFormat::Snippet
                } else {
                    TextInsertFormat::PlainText
                };
                item.detail = source.detail.clone();
                item.documentation = source.documentation.clone();
                item.filter_text = source.filter_text.clone();
                item.replacement = source.replacement.map(&range);
                item.additional_edits = source
                    .additional_edits
                    .iter()
                    .map(|edit| TextCompletionEdit::new(range(edit.range), edit.text.clone()))
                    .collect();
                item
            })
            .collect()
    }
}

/// The server's items behind the list on screen, so a highlighted one can
/// fetch the documentation the list left out.
#[derive(Default)]
pub struct ScriptCompletionItems {
    items: RefCell<BTreeMap<String, ScriptCompletionItem>>,
}

impl ScriptCompletionItems {
    pub fn new() -> Self {
        Self::default()
    }

    /// Keeps a copy of every server item keyed by id, so a later resolve can
    /// name the one the list is showing.
    pub fn convert(
        &self,
        result: &ScriptCompletionResult,
        request: &TextCompletionRequest,
    ) -> Vec<TextCompletionItem> {
        {
            let mut items = self.items.borrow_mut();
            items.clear();
            for item in &result.items {
                // `uniquingKeysWith: { first, _ in first }` — the first id wins.
                items.entry(item.id()).or_insert_with(|| item.clone());
            }
        }
        ScriptCompletionConversion::items(result, request)
    }

    /// Documentation arrives only when the user highlights a row; the reply is
    /// called with the same item when the server has nothing more to say.
    pub fn resolver(self: &Rc<Self>, manager: &Rc<DynamicScriptManager>) -> TextCompletionResolver {
        let cache = self.clone();
        let manager = manager.clone();
        Rc::new(move |item, reply| {
            let Some(source) = cache.items.borrow().get(&item.id).cloned() else {
                reply(item);
                return;
            };
            let Ok(resolved) = manager.resolve_completion(&source) else {
                reply(item);
                return;
            };
            let mut next = item;
            next.documentation = resolved.documentation;
            next.detail = resolved.detail.or(next.detail);
            reply(next);
        })
    }
}
