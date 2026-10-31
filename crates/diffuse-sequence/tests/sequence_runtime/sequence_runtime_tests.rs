//! `SequenceRuntimeTests` — Swift suite `SequenceRuntime`.

use diffuse_sequence::binding_validator::{BindingValidator, RenderValidationResult};
use diffuse_sequence::cache_validator::CacheValidator;
use diffuse_sequence::clip_scheduler::{
    ClipScheduler, SequenceEvaluationOptions, SequenceFPSRemapMode,
};
use diffuse_sequence::override_resolver::OverrideResolver;
use diffuse_sequence::sequence_document::{
    Binding, BindingResolutionStatus, Clip, Cut, CutTransition, FrameRange, Marker, MarkerKind,
    OverrideTargetKind, SceneTargetReference, SequenceCache, SequenceCacheInvalidationPolicy,
    SequenceCacheKind, SequenceDocument, SequenceRevision, SequenceValue, Shot, ShotOverride,
    TimeBase, Track, TrackKind,
};
use diffuse_sequence::shot_evaluator::ShotEvaluator;

fn camera_binding() -> Binding {
    let mut binding = Binding::new("binding.camera".to_string(), "main_camera");
    binding.resolved_target = Some(SceneTargetReference::new(
        "scene://main",
        "camera.main",
        None,
    ));
    binding.resolution_status = BindingResolutionStatus::Bound;
    binding
}

// "clip scheduler maps sequence frame into shot and source time"
#[test]
fn clip_scheduler_maps_frames() {
    let mut clip = Clip::new(
        "clip.anim".to_string(),
        "Hero Walk",
        FrameRange::new(10, 20),
    );
    clip.source_offset = 40;
    clip.time_warp = 2.0;

    let mut track = Track::new("track.anim".to_string(), "Animation", TrackKind::Animation);
    track.clips = vec![clip];

    let mut shot = Shot::new(
        "shot.a".to_string(),
        "sc010_sh020",
        FrameRange::new(100, 160),
        camera_binding(),
    );
    shot.source_offset = 8;
    shot.tracks = vec![track];

    let scheduled = ClipScheduler::active_clips(&shot, 104, &SequenceEvaluationOptions::default());

    assert_eq!(scheduled.len(), 1);
    assert_eq!(scheduled[0].shot_id, "shot.a");
    assert_eq!(scheduled[0].track_id, "track.anim");
    assert_eq!(scheduled[0].shot_frame, 12);
    assert_eq!(scheduled[0].source_frame, 44.0);
}

// "clip scheduler treats zero time warp as a hold"
#[test]
fn zero_time_warp_holds_first_source_frame() {
    let mut clip = Clip::new("clip.hold".to_string(), "Hold", FrameRange::new(0, 10));
    clip.source_offset = 18;
    clip.time_warp = 0.0;

    let mut track = Track::new("track.anim".to_string(), "Animation", TrackKind::Animation);
    track.clips = vec![clip];

    let mut shot = Shot::new(
        "shot.a".to_string(),
        "sc010_sh020",
        FrameRange::new(0, 20),
        camera_binding(),
    );
    shot.tracks = vec![track];

    let scheduled = ClipScheduler::active_clips(&shot, 6, &SequenceEvaluationOptions::default());

    assert_eq!(scheduled.len(), 1);
    assert_eq!(scheduled[0].source_frame, 18.0);
}

// "shot evaluator honors mute and solo filtering"
#[test]
fn evaluator_honors_mute_and_solo() {
    let clip_a = Clip::new("clip.a".to_string(), "A", FrameRange::new(0, 10));
    let clip_b = Clip::new("clip.b".to_string(), "B", FrameRange::new(0, 10));

    let mut track_a = Track::new("track.a".to_string(), "Animation", TrackKind::Animation);
    track_a.mute = true;
    track_a.clips = vec![clip_a];

    let mut track_b = Track::new("track.b".to_string(), "Camera", TrackKind::Camera);
    track_b.clips = vec![clip_b];

    let mut shot = Shot::new(
        "shot.a".to_string(),
        "sc010_sh020",
        FrameRange::new(0, 20),
        camera_binding(),
    );
    shot.tracks = vec![track_a, track_b];

    let mut sequence = SequenceDocument::new(
        "doc".to_string(),
        "Test",
        "scene://main",
        FrameRange::new(0, 20),
    );
    sequence.shots = vec![shot];

    let mut solo = std::collections::BTreeSet::new();
    solo.insert("track.b".to_string());
    let evaluated = ShotEvaluator::evaluate(&sequence, 5, &SequenceEvaluationOptions::new(solo));

    assert_eq!(
        evaluated.shot.as_ref().map(|shot| shot.shot_id.clone()),
        Some("shot.a".to_string())
    );
    assert_eq!(evaluated.active_clips.len(), 1);
    assert_eq!(evaluated.active_clips[0].track_id, "track.b");
}

// "shot evaluator reports active markers and cut progress"
#[test]
fn evaluator_reports_markers_and_cut_progress() {
    let shot = Shot::new(
        "shot.a".to_string(),
        "sc010_sh020",
        FrameRange::new(20, 60),
        camera_binding(),
    );
    let marker = Marker::new("marker.sync".to_string(), 24, MarkerKind::SyncPoint, "beat");
    let mut cut = Cut::new("cut.dissolve".to_string(), 24, CutTransition::Dissolve);
    cut.duration = 6;

    let mut sequence = SequenceDocument::new(
        "doc".to_string(),
        "Test",
        "scene://main",
        FrameRange::new(0, 60),
    );
    sequence.shots = vec![shot];
    sequence.markers = vec![marker];
    sequence.cuts = vec![cut];

    let at_marker = ShotEvaluator::evaluate(&sequence, 24, &SequenceEvaluationOptions::default());
    let during_cut = ShotEvaluator::evaluate(&sequence, 27, &SequenceEvaluationOptions::default());

    assert_eq!(
        at_marker
            .active_markers
            .iter()
            .map(|marker| marker.id.clone())
            .collect::<Vec<_>>(),
        vec!["marker.sync".to_string()]
    );
    assert_eq!(
        during_cut.active_cut.as_ref().map(|cut| cut.cut.id.clone()),
        Some("cut.dissolve".to_string())
    );
    assert!(
        ((during_cut
            .active_cut
            .as_ref()
            .map(|cut| cut.progress)
            .unwrap_or(0.0))
            - 0.5)
            .abs()
            < 0.000_1
    );
}

// "fps remap supports duration ratio and frame count modes"
#[test]
fn fps_remap_supports_multiple_modes() {
    let original = FrameRange::new(0, 48);
    let source = TimeBase::with_fps(24);
    let destination = TimeBase::with_fps(30);

    let ratio = ClipScheduler::remap_frame_range(
        original,
        &source,
        &destination,
        SequenceFPSRemapMode::PreserveDurationRatio,
    );
    let frame_count = ClipScheduler::remap_frame_range(
        original,
        &source,
        &destination,
        SequenceFPSRemapMode::PreserveFrameCount,
    );

    assert_eq!(ratio, FrameRange::new(0, 60));
    assert_eq!(frame_count, original);
}

// "track Codable omits solo and lock session state"
#[test]
fn track_codable_omits_session_state() {
    let mut track = Track::new("track.a".to_string(), "Animation", TrackKind::Animation);
    track.solo = true;
    track.lock = true;
    track.color_token = "cyan".to_string();

    let data = serde_json::to_string(&track).expect("encode track");
    let decoded: Track = serde_json::from_str(&data).expect("decode track");

    assert!(!data.contains("solo"));
    assert!(!data.contains("lock"));
    assert!(!decoded.solo);
    assert!(!decoded.lock);
    assert_eq!(decoded.color_token, "cyan");
    // The explicit CodingKeys rename must stay in the payload.
    assert!(data.contains("\"color_token\""));
}

// "override resolver returns blend weights at shot boundaries"
#[test]
fn override_resolver_blend_weight() {
    let mut shot_override = ShotOverride::new(
        "ov.brightness".to_string(),
        OverrideTargetKind::LightParam,
        SceneTargetReference::new("scene://main", "light.key", Some("intensity".to_string())),
        SequenceValue::Number(2.5),
    );
    shot_override.blend_in_frames = 10;
    shot_override.blend_out_frames = 10;

    let mut shot = Shot::new(
        "shot.a".to_string(),
        "sc010_sh020",
        FrameRange::new(100, 160),
        camera_binding(),
    );
    shot.overrides = vec![shot_override];

    let at_start = OverrideResolver::active_overrides(&shot, 100);
    let mid_blend_in = OverrideResolver::active_overrides(&shot, 105);
    let fully_on = OverrideResolver::active_overrides(&shot, 120);
    let mid_blend_out = OverrideResolver::active_overrides(&shot, 155);
    let outside_shot = OverrideResolver::active_overrides(&shot, 160);

    assert_eq!(at_start.len(), 0);
    assert_eq!(mid_blend_in.len(), 1);
    assert!((mid_blend_in[0].weight - 0.5).abs() < 0.001);
    assert_eq!(fully_on.len(), 1);
    assert!((fully_on[0].weight - 1.0).abs() < 0.001);
    assert_eq!(mid_blend_out.len(), 1);
    assert!((mid_blend_out[0].weight - 0.5).abs() < 0.001);
    assert_eq!(outside_shot.len(), 0);
}

// "cache strict policy invalidates on revision mismatch"
#[test]
fn cache_strict_policy_invalidates_on_revision_mismatch() {
    let baked_revision = SequenceRevision::new("rev-001".to_string());
    let current_revision = SequenceRevision::new("rev-002".to_string());

    let strict_cache = SequenceCache::new(
        "cache.physics".to_string(),
        SequenceCacheKind::Physics,
        "shot.a",
        None,
        FrameRange::new(0, 60),
        "cache://physics.bin",
        baked_revision.clone(),
    );
    let mut tolerant_cache = SequenceCache::new(
        "cache.cloth".to_string(),
        SequenceCacheKind::Cloth,
        "shot.a",
        None,
        FrameRange::new(0, 60),
        "cache://cloth.bin",
        baked_revision.clone(),
    );
    tolerant_cache.invalidation_policy = SequenceCacheInvalidationPolicy::Tolerant;

    let strict_result = CacheValidator::validate(&strict_cache, &current_revision);
    let tolerant_result = CacheValidator::validate(&tolerant_cache, &current_revision);
    let fresh_strict = CacheValidator::validate(&strict_cache, &baked_revision);

    assert!(!strict_result.is_valid);
    assert!(strict_result.is_stale);
    assert!(tolerant_result.is_valid);
    assert!(tolerant_result.is_stale);
    assert!(fresh_strict.is_valid);
    assert!(!fresh_strict.is_stale);
}

// "binding validator blocks render when bindings are not bound"
#[test]
fn binding_validator_blocks_render_when_unbound() {
    let mut bound_binding = Binding::new("binding.hero".to_string(), "main_character");
    bound_binding.resolved_target = Some(SceneTargetReference::new(
        "scene://main",
        "entity.hero",
        None,
    ));
    bound_binding.resolution_status = BindingResolutionStatus::Bound;

    let mut stale_binding = Binding::new("binding.prop".to_string(), "hero_prop");
    stale_binding.resolution_status = BindingResolutionStatus::Stale;

    let mut clip = Clip::new("clip.anim".to_string(), "Hero Walk", FrameRange::new(0, 24));
    clip.bindings = vec![bound_binding, stale_binding];

    let mut track = Track::new("track.anim".to_string(), "Animation", TrackKind::Animation);
    track.clips = vec![clip];

    let mut shot = Shot::new(
        "shot.a".to_string(),
        "sc010_sh020",
        FrameRange::new(0, 60),
        camera_binding(),
    );
    shot.tracks = vec![track];

    let mut sequence = SequenceDocument::new(
        "doc".to_string(),
        "Test",
        "scene://main",
        FrameRange::new(0, 60),
    );
    sequence.shots = vec![shot];

    let result = BindingValidator::validate_for_render(&sequence);
    let RenderValidationResult::Blocked(ids) = result else {
        panic!("expected .blocked but got .ok");
    };
    assert!(ids.contains(&"binding.prop".to_string()));
    assert!(!ids.contains(&"binding.hero".to_string()));
}

// "document-level FPS remap scales all frame ranges proportionally"
#[test]
fn document_fps_remap_scales_all_ranges() {
    let mut clip = Clip::new("clip.anim".to_string(), "Hero Walk", FrameRange::new(0, 24));
    clip.blend_in_frames = 6;

    let mut track = Track::new("track.anim".to_string(), "Animation", TrackKind::Animation);
    track.clips = vec![clip];

    let mut shot = Shot::new(
        "shot.a".to_string(),
        "sc010_sh020",
        FrameRange::new(0, 48),
        camera_binding(),
    );
    shot.tracks = vec![track];

    let mut cut = Cut::new("cut.dissolve".to_string(), 24, CutTransition::Dissolve);
    cut.duration = 12;

    let marker = Marker::new("marker.beat".to_string(), 12, MarkerKind::SyncPoint, "beat");

    let mut sequence = SequenceDocument::new(
        "doc".to_string(),
        "Test",
        "scene://main",
        FrameRange::new(0, 48),
    );
    sequence.shots = vec![shot];
    sequence.markers = vec![marker];
    sequence.cuts = vec![cut];

    let remapped = sequence.remapping(24, 30, SequenceFPSRemapMode::PreserveDurationRatio);

    assert_eq!(remapped.time_base.fps, 30);
    assert_eq!(remapped.frame_range, FrameRange::new(0, 60));
    assert_eq!(remapped.shots[0].range, FrameRange::new(0, 60));
    assert_eq!(
        remapped.shots[0].tracks[0].clips[0].shot_range,
        FrameRange::new(0, 30)
    );
    assert_eq!(remapped.shots[0].tracks[0].clips[0].blend_in_frames, 8);
    assert_eq!(remapped.cuts[0].frame, 30);
    assert_eq!(remapped.cuts[0].duration, 15);
    assert_eq!(remapped.markers[0].frame, 15);
}
