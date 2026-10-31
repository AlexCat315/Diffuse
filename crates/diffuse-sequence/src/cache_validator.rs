//! `CacheValidator` — decides whether a baked cache may be used for evaluation.

use crate::sequence_document::{
    SequenceCache, SequenceCacheInvalidationPolicy, SequenceRevision,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CacheValidationResult {
    pub is_valid: bool,
    pub is_stale: bool,
    pub reason: Option<String>,
}

impl CacheValidationResult {
    pub const VALID: CacheValidationResult =
        CacheValidationResult { is_valid: true, is_stale: false, reason: None };

    #[inline]
    pub fn new(is_valid: bool, is_stale: bool, reason: Option<String>) -> Self {
        CacheValidationResult { is_valid, is_stale, reason }
    }
}

pub enum CacheValidator {}

impl CacheValidator {
    /// - strict: the cache source revision must match `current_revision.id` exactly.
    /// - tolerant: a stale cache is readable, but `is_stale` is reported. Never use
    ///   tolerant mode for a final render submission.
    pub fn validate(
        cache: &SequenceCache,
        current_revision: &SequenceRevision,
    ) -> CacheValidationResult {
        let revision_matches = cache.source_revision.id == current_revision.id;
        match cache.invalidation_policy {
            SequenceCacheInvalidationPolicy::Strict => {
                if revision_matches {
                    return CacheValidationResult::VALID;
                }
                CacheValidationResult::new(
                    false,
                    true,
                    Some(format!(
                        "strict cache '{}' source revision '{}' does not match current revision '{}'",
                        cache.id, cache.source_revision.id, current_revision.id
                    )),
                )
            }
            SequenceCacheInvalidationPolicy::Tolerant => CacheValidationResult::new(
                true,
                !revision_matches,
                if revision_matches {
                    None
                } else {
                    Some(format!(
                        "tolerant cache '{}' is stale but still readable",
                        cache.id
                    ))
                },
            ),
        }
    }

    /// The first valid cache entry for `shot_id` covering `frame` under the current
    /// revision.
    pub fn best_cache<'a>(
        caches: &'a [SequenceCache],
        shot_id: &str,
        frame: i64,
        current_revision: &SequenceRevision,
    ) -> Option<&'a SequenceCache> {
        let mut candidates: Vec<&SequenceCache> = caches
            .iter()
            .filter(|cache| {
                cache.shot_id == shot_id
                    && cache.range.contains(frame)
                    && Self::validate(cache, current_revision).is_valid
            })
            .collect();
        // Swift sorted by "covers frame and the other does not", then took the first.
        candidates.sort_by_key(|cache| !cache.range.contains(frame));
        candidates.into_iter().next()
    }
}
