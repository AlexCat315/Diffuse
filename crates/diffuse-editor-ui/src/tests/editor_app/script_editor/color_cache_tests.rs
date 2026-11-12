//! Ported from `Editor/Tests/EditorAppTests/ScriptEditor/ColorCacheTests.swift`.

/// Repeated glyph and minimap queries reuse colored and plain decisions.
#[test]
fn repeated_queries() {
    use crate::panels::script_editor::syntax::color_cache::ScriptSyntaxColorCache;
    use crate::panels::script_editor::syntax::syntax::SwiftSyntaxTokenKind;

    let mut cache = ScriptSyntaxColorCache::new();
    let mut queries = 0;
    for _ in 0..100 {
        assert_eq!(
            cache.kind(3, || {
                queries += 1;
                Some(SwiftSyntaxTokenKind::Keyword)
            }),
            Some(SwiftSyntaxTokenKind::Keyword)
        );
        assert_eq!(
            cache.kind(7, || {
                queries += 1;
                None
            }),
            None
        );
    }
    assert_eq!(queries, 2);
    cache.invalidate();
    assert_eq!(
        cache.kind(3, || {
            queries += 1;
            Some(SwiftSyntaxTokenKind::StringLiteral)
        }),
        Some(SwiftSyntaxTokenKind::StringLiteral)
    );
    assert_eq!(
        cache.kind(7, || {
            queries += 1;
            Some(SwiftSyntaxTokenKind::Comment)
        }),
        Some(SwiftSyntaxTokenKind::Comment)
    );
    assert_eq!(queries, 4);
}
