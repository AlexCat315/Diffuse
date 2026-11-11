//! Path-style glob limited to `*` and `?` within one path component, matching
//! what `Path.glob` was asked for (`*.bundle`, `C*.modulemap`,
//! `C*.build/module.modulemap`). A missing directory yields no matches, as
//! Python's `Path.glob` does.

use std::path::{Path, PathBuf};

pub struct Glob;

impl Glob {
    pub fn paths(directory: &Path, pattern: &str) -> Vec<PathBuf> {
        let mut results = vec![directory.to_path_buf()];
        for component in pattern.split('/') {
            let mut next: Vec<PathBuf> = Vec::new();
            for base in &results {
                if component.contains('*') || component.contains('?') {
                    let entries = std::fs::read_dir(base)
                        .map(|entries| {
                            entries
                                .filter_map(Result::ok)
                                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    let mut matched: Vec<String> = entries
                        .into_iter()
                        .filter(|name| Self::matches(name, component))
                        .collect();
                    matched.sort();
                    next.extend(matched.into_iter().map(|name| base.join(name)));
                } else {
                    let candidate = base.join(component);
                    if candidate.exists() {
                        next.push(candidate);
                    }
                }
            }
            results = next;
        }
        results
    }

    /// `^…$` over the whole name, where `*` stops at a separator and `?`
    /// matches exactly one non-separator character.
    pub fn matches(name: &str, pattern: &str) -> bool {
        let name: Vec<char> = name.chars().collect();
        let pattern: Vec<char> = pattern.chars().collect();
        Self::matches_at(&name, 0, &pattern, 0)
    }

    fn matches_at(name: &[char], name_at: usize, pattern: &[char], pattern_at: usize) -> bool {
        if pattern_at == pattern.len() {
            return name_at == name.len();
        }
        match pattern[pattern_at] {
            '*' => {
                let mut index = name_at;
                loop {
                    if Self::matches_at(name, index, pattern, pattern_at + 1) {
                        return true;
                    }
                    if index == name.len() || name[index] == '/' {
                        return false;
                    }
                    index += 1;
                }
            }
            '?' => {
                name_at < name.len()
                    && name[name_at] != '/'
                    && Self::matches_at(name, name_at + 1, pattern, pattern_at + 1)
            }
            literal => {
                name_at < name.len()
                    && name[name_at] == literal
                    && Self::matches_at(name, name_at + 1, pattern, pattern_at + 1)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Glob;

    #[test]
    fn star_matches_within_one_component() {
        assert!(Glob::matches("CFreeType.bundle", "*.bundle"));
        assert!(Glob::matches("CFreeType.modulemap", "C*.modulemap"));
        assert!(!Glob::matches("a/b.bundle", "*.bundle"));
    }

    #[test]
    fn question_mark_matches_one_character() {
        assert!(Glob::matches("ab", "a?"));
        assert!(!Glob::matches("a", "a?"));
        assert!(!Glob::matches("a/", "a?"));
    }

    #[test]
    fn missing_directories_yield_no_matches() {
        assert!(Glob::paths(std::path::Path::new("/nonexistent/cove-glob"), "*").is_empty());
    }

    #[test]
    fn nested_patterns_walk_components() {
        let root = crate::validation::runtime::support::temp::directory("cove-glob-").unwrap();
        std::fs::create_dir_all(root.join("CWidget.build")).unwrap();
        std::fs::write(root.join("CWidget.build/module.modulemap"), "").unwrap();
        std::fs::write(root.join("Other.build"), "").unwrap();
        let matches = Glob::paths(&root, "C*.build/module.modulemap");
        assert_eq!(matches.len(), 1);
        assert!(matches[0].ends_with("CWidget.build/module.modulemap"));
        let _ = crate::support::files::remove(&root);
    }
}
