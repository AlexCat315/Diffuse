//! `Editor/Sources/EditorUI/AI/EditorCommandSearch.swift`.
//!
//! The palette's catalog, which is also the list an agent may reach, plus the
//! one scoring rule both searches share.
//!
//! Difference from Swift: `folding(options: [.caseInsensitive,
//! .diacriticInsensitive], locale: .current)` is a Unicode operation and Rust's
//! standard library has no normalisation form, so [`fold`] lowercases and strips
//! the precomposed Latin-1 accents with a built-in table. ASCII, Latin-1 and the
//! characters the localized command titles use fold identically; scripts outside
//! that table keep their diacritics, which can only cost a match, never add one.

use std::rc::Rc;

use diffuse_editor_core::application::editor_application::EditorApplication;

use crate::commands::catalog::{EditorCommandCatalog, EditorCommandContext, EditorCommandEntry};

/// Lowercases and removes the accent from the Latin letters people type into a
/// search field.
pub fn fold(text: &str) -> String {
    let mut folded = String::with_capacity(text.len());
    for character in text.chars() {
        let replacement = match character {
            'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' => Some("a"),
            'æ' => Some("ae"),
            'ç' => Some("c"),
            'è' | 'é' | 'ê' | 'ë' => Some("e"),
            'ì' | 'í' | 'î' | 'ï' => Some("i"),
            'ñ' => Some("n"),
            'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' => Some("o"),
            'œ' => Some("oe"),
            'ù' | 'ú' | 'û' | 'ü' => Some("u"),
            'ý' | 'ÿ' => Some("y"),
            'ß' => Some("ss"),
            _ => None,
        };
        match replacement {
            Some(replacement) => folded.push_str(replacement),
            None => folded.extend(character.to_lowercase()),
        }
    }
    folded
}

/// The palette lists the same catalog entries as the menus, minus the entries
/// that only open the palette itself.
pub fn commands(app: &Rc<EditorApplication>) -> Vec<EditorCommandEntry> {
    EditorCommandCatalog::make(&EditorCommandContext::from_application(app))
        .entries()
        .into_iter()
        .filter(|entry| entry.in_palette)
        .collect()
}

/// Exact and substring matches precede subsequence matches. Multi-word queries
/// must match every token; `None` means the query did not match at all.
pub fn score(query: &str, text: &str) -> Option<i64> {
    let haystack = fold(text);
    let mut total = 0i64;
    for token in query
        .split(|character: char| character.is_whitespace())
        .filter(|token| !token.is_empty())
    {
        let token = fold(token);
        if haystack == token {
            total += 100;
        } else if haystack.contains(&token) {
            total += 60;
        } else {
            let mut cursor = 0usize;
            let mut matched = true;
            for character in token.chars() {
                match haystack[cursor..].find(character) {
                    Some(offset) => cursor += offset + character.len_utf8(),
                    None => {
                        matched = false;
                        break;
                    }
                }
            }
            if !matched {
                return None;
            }
            total += 10;
        }
    }
    Some(total)
}
