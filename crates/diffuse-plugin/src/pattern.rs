//! The identifier shapes and the two pattern matchers this crate needs.
//!
//! Swift used `NSRegularExpression` in three ways, and each gets the smallest
//! mechanism that reproduces it (MIGRATION.md §5.7: no reimplementation of a
//! general engine):
//!
//! 1. **A fixed validation pattern** — every `…range(of: pattern, options:
//!    .regularExpression) != nil` on a constant like `^[a-z][a-z0-9.-]{2,63}$`.
//!    There are seventeen of these and each is "first character from one set,
//!    remaining characters from another, length in a range", so they are written
//!    as explicit character predicates below. No matcher is involved.
//! 2. **A workspace glob** — `PluginManager::matches` turns a manifest
//!    `onWorkspaceContains:` declaration into a regular expression by mapping `*`
//!    to `.*`, `?` to `.` and passing everything else through
//!    `NSRegularExpression.escapedPattern`, then anchors it with `^`…`$`. That is
//!    a glob, so [`glob_matches`] matches it directly.
//! 3. **A plugin-supplied grammar rule** — `LanguageContributionPoint` compiles
//!    the package's own `grammar.rules[].pattern` / `outline.rules[].pattern`
//!    with `.anchorsMatchLines` and, for outlines, requires at least one capture
//!    group. The pattern is untrusted data arriving at run time, so
//!    [`plugin_pattern`] validates the syntax of the subset a grammar rule can
//!    reasonably use and counts its capture groups. A construct outside that
//!    subset is rejected, which fails closed: it can refuse a declaration, never
//!    accept a malformed one.

/// `first` plus `rest`, with a grapheme count in `min..=max`.
///
/// Swift's `{n,m}` counted `Character`s. Every set used here is ASCII, so a
/// non-ASCII scalar fails the predicate before the count can disagree.
fn shape(
    value: &str,
    minimum: usize,
    maximum: usize,
    first: fn(char) -> bool,
    rest: fn(char) -> bool,
) -> bool {
    let mut characters = value.chars();
    let Some(head) = characters.next() else {
        return false;
    };
    if !first(head) {
        return false;
    }
    let mut count = 1usize;
    for character in characters {
        if !rest(character) {
            return false;
        }
        count += 1;
    }
    count <= maximum && count >= minimum
}

fn lower(character: char) -> bool {
    character.is_ascii_lowercase()
}

fn digit(character: char) -> bool {
    character.is_ascii_digit()
}

fn lower_or_digit(character: char) -> bool {
    lower(character) || digit(character)
}

fn alphanumeric(character: char) -> bool {
    character.is_ascii_alphanumeric()
}

fn underscore(character: char) -> bool {
    character == '_'
}

fn dot(character: char) -> bool {
    character == '.'
}

fn dash(character: char) -> bool {
    character == '-'
}

/// `^[a-z][a-z0-9-]{n,m}$` — contribution `identifier`s, capability entry
/// points, HTTP permission ids.
pub fn lower_dash(value: &str, minimum: usize, maximum: usize) -> bool {
    shape(value, minimum, maximum, lower, |character| {
        lower_or_digit(character) || dash(character)
    })
}

/// `^[a-z][a-z0-9.]{n,m}$` — plugin ids, theme ids, panel surfaces.
pub fn lower_dot(value: &str, minimum: usize, maximum: usize) -> bool {
    shape(value, minimum, maximum, lower, |character| {
        lower_or_digit(character) || dot(character)
    })
}

/// `^[a-z][a-z0-9._-]{n,m}$` — capability requirement ids, AI tool entry points.
pub fn lower_capability(value: &str, minimum: usize, maximum: usize) -> bool {
    shape(value, minimum, maximum, lower, |character| {
        lower_or_digit(character) || dot(character) || underscore(character) || dash(character)
    })
}

/// `^[a-z][a-zA-Z0-9_.-]{n,m}$` — component ids and action names.
pub fn lower_component(value: &str, minimum: usize, maximum: usize) -> bool {
    shape(value, minimum, maximum, lower, |character| {
        alphanumeric(character) || underscore(character) || dot(character) || dash(character)
    })
}

/// `^[a-z][a-zA-Z0-9-]{n,m}$` — a TypeScript `capabilities.json` field name.
pub fn lower_alphanumeric_dash(value: &str, minimum: usize, maximum: usize) -> bool {
    shape(value, minimum, maximum, lower, |character| {
        alphanumeric(character) || dash(character)
    })
}

/// `^[a-z0-9_-]{n,m}$` — icon keys.
pub fn icon(value: &str, minimum: usize, maximum: usize) -> bool {
    shape(
        value,
        minimum,
        maximum,
        |character| lower_or_digit(character) || underscore(character) || dash(character),
        |character| lower_or_digit(character) || underscore(character) || dash(character),
    )
}

/// `^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$` — a process permission id or command.
pub fn process_token(value: &str) -> bool {
    shape(value, 1, 80, alphanumeric, |character| {
        alphanumeric(character) || dot(character) || underscore(character) || dash(character)
    })
}

/// `^[A-Za-z_][A-Za-z0-9_]{0,79}$` — a process environment key.
pub fn environment_key(value: &str) -> bool {
    shape(
        value,
        1,
        80,
        |character| character.is_ascii_alphabetic() || underscore(character),
        |character| character.is_ascii_alphanumeric() || underscore(character),
    )
}

/// `^[A-Z][A-Z0-9_]{0,63}$` — an auth contribution's environment variable.
pub fn upper_environment_variable(value: &str) -> bool {
    shape(
        value,
        1,
        64,
        |character| character.is_ascii_uppercase(),
        |character| character.is_ascii_uppercase() || digit(character) || underscore(character),
    )
}

/// `^[A-Za-z0-9_+-]{1,16}$` (language) and `^[a-z0-9_+-]{1,16}$` (document view)
/// — file name extensions.
pub fn file_extension(value: &str, allow_uppercase: bool) -> bool {
    // `shape` takes bare `fn` pointers, so the two variants are two functions
    // rather than one closure.
    fn upper_allowed(character: char) -> bool {
        character.is_ascii_alphanumeric()
            || underscore(character)
            || character == '+'
            || dash(character)
    }
    fn lower_allowed(character: char) -> bool {
        lower_or_digit(character) || underscore(character) || character == '+' || dash(character)
    }
    if allow_uppercase {
        shape(value, 1, 16, upper_allowed, upper_allowed)
    } else {
        shape(value, 1, 16, lower_allowed, lower_allowed)
    }
}

/// `^[a-z][a-z0-9.-]{2,95}/v[1-9][0-9]*$` — a service or extension point id.
pub fn extension_id(value: &str) -> bool {
    let Some((head, version)) = value.split_once("/v") else {
        return false;
    };
    lower_dot(head, 3, 96) && version_number(version)
}

/// `^cove\.[a-z][a-zA-Z0-9]*(?:\.[a-z][a-zA-Z0-9]*)*/v[1-9][0-9]*$` — a
/// contribution point id.
pub fn contribution_point_id(value: &str) -> bool {
    let Some((head, version)) = value.split_once("/v") else {
        return false;
    };
    if !version_number(version) {
        return false;
    }
    let Some(rest) = head.strip_prefix("cove.") else {
        return false;
    };
    // One or more dot-separated segments, each `[a-z][a-zA-Z0-9]*`.
    rest.split('.').all(|segment| {
        let mut characters = segment.chars();
        characters
            .next()
            .is_some_and(|head| head.is_ascii_lowercase())
            && characters.all(|character| character.is_ascii_alphanumeric())
    })
}

/// `[1-9][0-9]*`.
fn version_number(value: &str) -> bool {
    let mut characters = value.chars();
    characters
        .next()
        .is_some_and(|head| ('1'..='9').contains(&head))
        && characters.all(digit)
}

/// `^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(:\d{1,5})?$`,
/// matched case-insensitively.
///
/// Each label is 1–63 characters drawn from `[a-z0-9-]`, and a label longer than
/// one character may not start or end with `-`. The whole rule never exceeds
/// 253 characters, checked by the caller.
pub fn host_pattern(value: &str) -> bool {
    if value.contains('/') || value.contains('@') || value.contains(' ') {
        return false;
    }
    let lowered = value.to_ascii_lowercase();
    let (host, port) = match lowered.split_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (lowered.as_str(), None),
    };
    if let Some(port) = port
        && (port.is_empty() || port.len() > 5 || !port.chars().all(digit))
    {
        return false;
    }
    let host = host.strip_prefix("*.").unwrap_or(host);
    if host.is_empty() {
        return false;
    }
    host.split('.').all(|label| {
        if label.is_empty() || label.len() > 63 {
            return false;
        }
        if !label
            .chars()
            .all(|character| lower_or_digit(character) || dash(character))
        {
            return false;
        }
        let first = label.chars().next().unwrap_or('-');
        let last = label.chars().next_back().unwrap_or('-');
        first != '-' && last != '-'
    })
}

/// `PluginManager::matches` for `onWorkspaceContains:` declarations.
///
/// Swift built `"^" + escaped(pattern with * → .* and ? → .) + "$"` and tested the
/// event's path against it, so this is a full-string glob match: `*` matches any
/// run (possibly empty), `?` matches exactly one character, everything else is
/// literal.
pub fn glob_matches(pattern: &str, path: &str) -> bool {
    let pattern: Vec<char> = pattern.chars().collect();
    let path: Vec<char> = path.chars().collect();
    // Iterative backtracking keeps the star's resume point, so the match stays
    // linear without recursion.
    let (mut pattern_index, mut path_index) = (0usize, 0usize);
    let mut star: Option<(usize, usize)> = None;
    while path_index < path.len() {
        if pattern_index < pattern.len()
            && (pattern[pattern_index] == '?' || pattern[pattern_index] == path[path_index])
        {
            pattern_index += 1;
            path_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == '*' {
            star = Some((pattern_index, path_index));
            pattern_index += 1;
        } else if let Some((star_index, star_path)) = star {
            pattern_index = star_index + 1;
            path_index = star_path + 1;
            star = Some((star_index, star_path + 1));
        } else {
            return false;
        }
    }
    while pattern_index < pattern.len() && pattern[pattern_index] == '*' {
        pattern_index += 1;
    }
    pattern_index == pattern.len()
}

/// The plugin-supplied grammar-rule patterns `LanguageContributionPoint`
/// compiles with `NSRegularExpression(pattern:options: [.anchorsMatchLines])`.
pub mod plugin_pattern {
    /// A pattern `NSRegularExpression` would have thrown on.
    #[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
    #[error("invalid regular expression: {0}")]
    pub struct PatternError(pub String);

    /// Compile result: whether the pattern is well formed and how many capture
    /// groups it declares.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct Compiled {
        pub capture_groups: usize,
    }

    /// Validates the syntax and counts capture groups.
    ///
    /// Supports literals, `.`, escaped literals, character classes with ranges
    /// and negation, groups (capturing and `(?:`), alternation, the `*`, `+`,
    /// `?`, `{n}`, `{n,}` and `{n,m}` quantifiers, and the `^`/`$` anchors —
    /// enough for a colouring or outline rule, which is what a grammar rule is.
    pub fn compile(pattern: &str) -> Result<Compiled, PatternError> {
        let characters: Vec<char> = pattern.chars().collect();
        let mut position = 0usize;
        // Alternation depth is tracked by the group stack; a bare `|` at depth 0
        // is valid, so only `)` needs to know whether it closes something.
        let mut captures = 0usize;
        let mut groups: Vec<bool> = Vec::new();
        let mut pending_atom = false;
        while position < characters.len() {
            let character = characters[position];
            match character {
                '(' => {
                    position += 1;
                    if characters.get(position) == Some(&'?') {
                        if characters.get(position + 1) != Some(&':') {
                            return Err(PatternError(format!(
                                "unsupported group construct at offset {position}"
                            )));
                        }
                        position += 2;
                        groups.push(false);
                    } else {
                        captures += 1;
                        groups.push(true);
                    }
                    pending_atom = false;
                }
                ')' => {
                    if groups.pop().is_none() {
                        return Err(PatternError(format!("unmatched ')' at offset {position}")));
                    }
                    position += 1;
                    pending_atom = true;
                }
                '|' => {
                    position += 1;
                    pending_atom = false;
                }
                '[' => {
                    position += 1;
                    if characters.get(position) == Some(&'^') {
                        position += 1;
                    }
                    let mut items = 0usize;
                    let mut first = true;
                    loop {
                        let Some(item) = characters.get(position).copied() else {
                            return Err(PatternError("unterminated character class".to_string()));
                        };
                        if item == ']' && !first {
                            position += 1;
                            break;
                        }
                        first = false;
                        if item == '\\' {
                            position += 2;
                        } else {
                            position += 1;
                        }
                        // A range needs both endpoints.
                        if characters.get(position) == Some(&'-')
                            && characters
                                .get(position + 1)
                                .is_some_and(|next| *next != ']')
                        {
                            position += 1;
                            if characters.get(position) == Some(&'\\') {
                                position += 2;
                            } else {
                                position += 1;
                            }
                        }
                        items += 1;
                    }
                    if items == 0 {
                        return Err(PatternError("empty character class".to_string()));
                    }
                    pending_atom = true;
                }
                '\\' => {
                    position += 1;
                    if position >= characters.len() {
                        return Err(PatternError("trailing backslash".to_string()));
                    }
                    position += 1;
                    pending_atom = true;
                }
                '*' | '+' | '?' => {
                    if !pending_atom {
                        return Err(PatternError(format!(
                            "nothing to repeat at offset {position}"
                        )));
                    }
                    position += 1;
                    // A trailing `?`/`+` marks the repetition lazy or possessive.
                    if matches!(characters.get(position), Some('?') | Some('+')) {
                        position += 1;
                    }
                }
                '{' => {
                    if !pending_atom {
                        return Err(PatternError(format!(
                            "nothing to repeat at offset {position}"
                        )));
                    }
                    position += 1;
                    let Some(minimum) = digits(&characters, &mut position) else {
                        return Err(PatternError(format!(
                            "expected a repetition count at offset {position}"
                        )));
                    };
                    let maximum = match characters.get(position) {
                        Some('}') => {
                            position += 1;
                            Some(minimum)
                        }
                        Some(',') => {
                            position += 1;
                            if characters.get(position) == Some(&'}') {
                                position += 1;
                                None
                            } else {
                                let Some(maximum) = digits(&characters, &mut position) else {
                                    return Err(PatternError(format!(
                                        "expected a repetition count at offset {position}"
                                    )));
                                };
                                if characters.get(position) != Some(&'}') {
                                    return Err(PatternError(
                                        "unterminated repetition".to_string(),
                                    ));
                                }
                                position += 1;
                                Some(maximum)
                            }
                        }
                        _ => {
                            return Err(PatternError("unterminated repetition".to_string()));
                        }
                    };
                    if maximum.is_some_and(|maximum| maximum < minimum) {
                        return Err(PatternError(
                            "repetition maximum is below minimum".to_string(),
                        ));
                    }
                    if matches!(characters.get(position), Some('?') | Some('+')) {
                        position += 1;
                    }
                }
                '^' | '$' => {
                    position += 1;
                    pending_atom = false;
                }
                '.' => {
                    position += 1;
                    pending_atom = true;
                }
                _ => {
                    position += 1;
                    pending_atom = true;
                }
            }
        }
        if !groups.is_empty() {
            return Err(PatternError("unterminated group".to_string()));
        }
        Ok(Compiled {
            capture_groups: captures,
        })
    }

    /// Reads a decimal repetition count.
    fn digits(characters: &[char], position: &mut usize) -> Option<usize> {
        let start = *position;
        while characters
            .get(*position)
            .is_some_and(|value| value.is_ascii_digit())
        {
            *position += 1;
        }
        if start == *position {
            return None;
        }
        characters[start..*position]
            .iter()
            .collect::<String>()
            .parse()
            .ok()
    }
}

/// `String.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`.
pub fn is_blank(value: &str) -> bool {
    value.chars().all(char::is_whitespace)
}

/// `rangeOfCharacter(from: .whitespacesAndNewlines) == nil`.
pub fn has_whitespace(value: &str) -> bool {
    value.chars().any(char::is_whitespace)
}

/// `string.count` — Swift counted extended grapheme clusters.
pub fn grapheme_count(value: &str) -> usize {
    unicode_segmentation::UnicodeSegmentation::graphemes(value, true).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plugin_ids_match_the_swift_pattern() {
        assert!(lower_dot("studio.core", 3, 64));
        assert!(lower_dot("a.b", 3, 64));
        assert!(!lower_dot("Studio.core", 3, 64));
        assert!(!lower_dot("a", 3, 64));
        // `.` is in the set, so a doubled dot is still well formed.
        assert!(lower_dot("studio..", 3, 64));
        assert!(!lower_dot("studio core", 3, 64));
        assert!(!lower_dot("", 3, 64));
    }

    #[test]
    fn contribution_point_ids_need_the_version_suffix() {
        assert!(contribution_point_id("cove.ui.panel/v1"));
        assert!(contribution_point_id("cove.theme/v1"));
        assert!(!contribution_point_id("cove.theme/v0"));
        assert!(!contribution_point_id("cove./v1"));
        assert!(!contribution_point_id("other.theme/v1"));
        assert!(!contribution_point_id("cove.theme"));
    }

    #[test]
    fn extension_ids_carry_a_version() {
        assert!(extension_id("studio.core/v2"));
        assert!(!extension_id("studio.core/v0"));
        assert!(!extension_id("Studio.core/v1"));
    }

    #[test]
    fn host_patterns_reject_smuggled_paths() {
        assert!(host_pattern("api.example.com"));
        assert!(host_pattern("*.example.com"));
        assert!(host_pattern("api.example.com:8080"));
        assert!(!host_pattern("https://api.example.com"));
        assert!(!host_pattern("user@api.example.com"));
        assert!(!host_pattern("api.example.com/v1"));
        assert!(!host_pattern("*"));
        assert!(!host_pattern(""));
        assert!(!host_pattern("-bad.example.com"));
    }

    #[test]
    fn globs_match_whole_paths() {
        assert!(glob_matches("**/Package.*", "App/Package.swift"));
        assert!(glob_matches("App/*.swift", "App/Package.swift"));
        assert!(glob_matches("*.swift", "Package.swift"));
        assert!(glob_matches("App/Package.?????", "App/Package.swift"));
        assert!(!glob_matches("App/*.rs", "App/Package.swift"));
        // `*` maps to `.*`, which crosses `/` — Swift's translation did too.
        assert!(glob_matches("*.swift", "App/Package.swift"));
        assert!(!glob_matches("App/Package.swift", "App/Package.swift.bak"));
    }

    #[test]
    fn grammar_patterns_compile_and_count_groups() {
        assert_eq!(
            plugin_pattern::compile(r"^abc$").map(|c| c.capture_groups),
            Ok(0)
        );
        assert_eq!(
            plugin_pattern::compile(r"^(#+)\s+(.*)$").map(|c| c.capture_groups),
            Ok(2)
        );
        assert_eq!(
            plugin_pattern::compile(r"^(?:a)(b)$").map(|c| c.capture_groups),
            Ok(1)
        );
        // `a\\` is an escaped backslash, which ICU accepts.
        assert!(plugin_pattern::compile(r"a\\").is_ok());
        for broken in ["(", "[a-", "a{2,1}", "*a", "[]", "a)"] {
            assert!(
                plugin_pattern::compile(broken).is_err(),
                "{broken} must not compile"
            );
        }
    }
}
