//! `SequenceDocument` and the serializable sequence model.
//!
//! Encodings follow Swift `Codable` (MIGRATION.md §5.4): synthesized member-wise
//! keys, `Track`'s explicit `CodingKeys` (`color_token`), and session-only state
//! (`solo`, `lock`) that Swift never wrote to disk.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::clip_scheduler::SequenceFPSRemapMode;
use crate::sequence_document_fps::remap_sequence_document;

/// Swift's `Date` epoch: 2001-01-01T00:00:00Z in Unix seconds.
pub const SWIFT_DATE_REFERENCE_UNIX_SECONDS: i64 = 978_307_200;

/// Swift `Date` encodes as seconds since 2001-01-01 in UTC.
pub fn date_to_swift_seconds(date: std::time::SystemTime) -> f64 {
    match date.duration_since(std::time::UNIX_EPOCH) {
        Ok(duration) => duration.as_secs_f64() - SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64,
        Err(_) => 0.0,
    }
}

/// Inverse of [`date_to_swift_seconds`].
pub fn swift_seconds_to_date(seconds: f64) -> std::time::SystemTime {
    let unix = seconds + SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64;
    if unix >= 0.0 {
        std::time::UNIX_EPOCH + std::time::Duration::from_secs_f64(unix)
    } else {
        std::time::UNIX_EPOCH - std::time::Duration::from_secs_f64(-unix)
    }
}

/// A timestamp carried in Swift's `Date` encoding.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SwiftDate(pub f64);

impl SwiftDate {
    #[inline]
    pub fn now() -> Self {
        SwiftDate(date_to_swift_seconds(std::time::SystemTime::now()))
    }

    #[inline]
    pub fn from_system_time(value: std::time::SystemTime) -> Self {
        SwiftDate(date_to_swift_seconds(value))
    }

    #[inline]
    pub fn to_system_time(self) -> std::time::SystemTime {
        swift_seconds_to_date(self.0)
    }
}

impl Serialize for SwiftDate {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_f64(self.0)
    }
}

impl<'de> Deserialize<'de> for SwiftDate {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<SwiftDate, D::Error> {
        f64::deserialize(deserializer).map(SwiftDate)
    }
}

/// A random v4 UUID formatted uppercase, matching Swift's `UUID().uuidString`.
pub fn new_uuid() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let time_low = (mixed & 0xFFFF_FFFF) as u32;
    let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
    let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
    let clock = ((counter & 0x3FFF) as u16) | 0x8000;
    let node_a = ((mixed >> 16) & 0xFFFF) as u16;
    let node_b = (mixed >> 8) as u32 & 0x00FF_FFFF;
    format!("{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node_a:04X}{node_b:06X}")
}

// MARK: - Timecode

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SmpteTimecode {
    pub hours: i64,
    pub minutes: i64,
    pub seconds: i64,
    pub frames: i64,
}

impl SmpteTimecode {
    #[inline]
    pub const fn new(hours: i64, minutes: i64, seconds: i64, frames: i64) -> Self {
        SmpteTimecode { hours, minutes, seconds, frames }
    }

    /// Swift defaults: `hours: 1`, everything else 0.
    pub const fn default_timecode() -> Self {
        SmpteTimecode { hours: 1, minutes: 0, seconds: 0, frames: 0 }
    }

    /// Swift's `String(format: "%02d:%02d:%02d:%02d", ...)`.
    pub fn description(&self) -> String {
        format!("{:02}:{:02}:{:02}:{:02}", self.hours, self.minutes, self.seconds, self.frames)
    }
}

impl Default for SmpteTimecode {
    fn default() -> Self {
        Self::default_timecode()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeBase {
    pub fps: i64,
    pub drop_frame: bool,
    pub start_timecode: SmpteTimecode,
}

impl TimeBase {
    /// Swift clamps `fps` to at least 1.
    #[inline]
    pub fn new(fps: i64, drop_frame: bool, start_timecode: SmpteTimecode) -> Self {
        TimeBase { fps: fps.max(1), drop_frame, start_timecode }
    }

    /// Swift defaults: 24 fps, no drop frame, `SMPTETimecode()`.
    pub fn default_time_base() -> Self {
        TimeBase { fps: 24, drop_frame: false, start_timecode: SmpteTimecode::default_timecode() }
    }

    pub fn with_fps(fps: i64) -> Self {
        TimeBase {
            fps: fps.max(1),
            drop_frame: false,
            start_timecode: SmpteTimecode::default_timecode(),
        }
    }

    #[inline]
    pub fn seconds(&self, frame: i64) -> f64 {
        frame as f64 / self.fps as f64
    }

    pub fn timecode(&self, frame: i64) -> SmpteTimecode {
        let safe_frame = frame.max(0);
        let fps = self.fps.max(1);
        let total_frames = self.start_timecode.frames + safe_frame;
        let frames = total_frames % fps;
        let total_seconds = self.start_timecode.seconds + (total_frames / fps);
        let seconds = total_seconds % 60;
        let total_minutes = self.start_timecode.minutes + (total_seconds / 60);
        let minutes = total_minutes % 60;
        let hours = self.start_timecode.hours + (total_minutes / 60);
        SmpteTimecode::new(hours, minutes, seconds, frames)
    }
}

impl Default for TimeBase {
    fn default() -> Self {
        Self::default_time_base()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrameRange {
    pub start: i64,
    pub end: i64,
}

impl FrameRange {
    #[inline]
    pub const fn new(start: i64, end: i64) -> Self {
        FrameRange { start, end }
    }

    #[inline]
    pub fn duration(&self) -> i64 {
        (self.end - self.start).max(0)
    }

    #[inline]
    pub fn contains(&self, frame: i64) -> bool {
        frame >= self.start && frame < self.end
    }

    #[inline]
    pub fn contains_range(&self, other: FrameRange) -> bool {
        other.start >= self.start && other.end <= self.end
    }

    #[inline]
    pub fn intersects(&self, other: FrameRange) -> bool {
        self.start < other.end && other.start < self.end
    }
}

// MARK: - SequenceValue

#[derive(Clone, Debug, PartialEq)]
pub enum SequenceValue {
    String(String),
    Integer(i64),
    Number(f64),
    Boolean(bool),
    Array(Vec<SequenceValue>),
    Object(std::collections::BTreeMap<String, SequenceValue>),
    Null,
}

impl Serialize for SequenceValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            SequenceValue::String(value) => serializer.serialize_str(value),
            SequenceValue::Integer(value) => serializer.serialize_i64(*value),
            SequenceValue::Number(value) => serializer.serialize_f64(*value),
            SequenceValue::Boolean(value) => serializer.serialize_bool(*value),
            SequenceValue::Array(values) => values.serialize(serializer),
            SequenceValue::Object(values) => values.serialize(serializer),
            SequenceValue::Null => serializer.serialize_unit(),
        }
    }
}

struct SequenceValueVisitor;

impl<'de> serde::de::Visitor<'de> for SequenceValueVisitor {
    type Value = SequenceValue;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a SequenceValue payload")
    }

    fn visit_unit<E: serde::de::Error>(self) -> Result<SequenceValue, E> {
        Ok(SequenceValue::Null)
    }

    fn visit_none<E: serde::de::Error>(self) -> Result<SequenceValue, E> {
        Ok(SequenceValue::Null)
    }

    fn visit_some<D: Deserializer<'de>>(self, deserializer: D) -> Result<SequenceValue, D::Error> {
        SequenceValue::deserialize(deserializer)
    }

    fn visit_bool<E: serde::de::Error>(self, value: bool) -> Result<SequenceValue, E> {
        Ok(SequenceValue::Boolean(value))
    }

    fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<SequenceValue, E> {
        Ok(SequenceValue::Integer(value))
    }

    fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<SequenceValue, E> {
        Ok(SequenceValue::Integer(value as i64))
    }

    fn visit_f64<E: serde::de::Error>(self, value: f64) -> Result<SequenceValue, E> {
        Ok(SequenceValue::Number(value))
    }

    fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<SequenceValue, E> {
        Ok(SequenceValue::String(value.to_string()))
    }

    fn visit_string<E: serde::de::Error>(self, value: String) -> Result<SequenceValue, E> {
        Ok(SequenceValue::String(value))
    }

    fn visit_seq<A: serde::de::SeqAccess<'de>>(
        self,
        mut seq: A,
    ) -> Result<SequenceValue, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = seq.next_element::<SequenceValue>()? {
            values.push(value);
        }
        Ok(SequenceValue::Array(values))
    }

    fn visit_map<A: serde::de::MapAccess<'de>>(
        self,
        mut map: A,
    ) -> Result<SequenceValue, A::Error> {
        let mut values = std::collections::BTreeMap::new();
        while let Some((key, value)) = map.next_entry::<String, SequenceValue>()? {
            values.insert(key, value);
        }
        Ok(SequenceValue::Object(values))
    }
}

impl<'de> Deserialize<'de> for SequenceValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<SequenceValue, D::Error> {
        deserializer.deserialize_any(SequenceValueVisitor)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SequenceEvaluationPolicy {
    Lazy,
    Eager,
    Hybrid,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SequenceProvenance {
    Authored,
    Inferred,
    Proposal,
    Baked,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceRevision {
    pub id: String,
    pub parent_id: Option<String>,
    pub author: String,
    pub created_at: SwiftDate,
    pub base_scene_revision_id: Option<String>,
    pub base_sequence_revision_id: Option<String>,
    pub transaction_ids: Vec<String>,
}

impl SequenceRevision {
    /// Swift defaults: nil parent, author `"system"`, now, no bases, no transactions.
    pub fn new(id: String) -> Self {
        SequenceRevision {
            id,
            parent_id: None,
            author: "system".to_string(),
            created_at: SwiftDate::now(),
            base_scene_revision_id: None,
            base_sequence_revision_id: None,
            transaction_ids: Vec::new(),
        }
    }

    /// Mirrors Swift's default-argument initializer (fresh UUID and timestamp).
    pub fn generate() -> Self {
        Self::new(new_uuid())
    }
}

impl Default for SequenceRevision {
    fn default() -> Self {
        Self::generate()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneTargetReference {
    pub doc_uri: String,
    pub target_id: String,
    pub sub_path: Option<String>,
}

impl SceneTargetReference {
    #[inline]
    pub fn new(
        doc_uri: impl Into<String>,
        target_id: impl Into<String>,
        sub_path: Option<String>,
    ) -> Self {
        SceneTargetReference { doc_uri: doc_uri.into(), target_id: target_id.into(), sub_path }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BindingFallbackStrategy {
    Skip,
    Proxy,
    Error,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BindingResolutionStatus {
    Bound,
    Unbound,
    Conflict,
    Stale,
}

impl BindingResolutionStatus {
    pub const fn raw_value(self) -> &'static str {
        match self {
            BindingResolutionStatus::Bound => "bound",
            BindingResolutionStatus::Unbound => "unbound",
            BindingResolutionStatus::Conflict => "conflict",
            BindingResolutionStatus::Stale => "stale",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Binding {
    pub id: String,
    pub abstract_role: String,
    pub resolved_target: Option<SceneTargetReference>,
    pub required_capabilities: Vec<String>,
    pub fallback_strategy: BindingFallbackStrategy,
    pub resolution_status: BindingResolutionStatus,
    pub resolved_at: Option<SwiftDate>,
}

impl Binding {
    /// Swift defaults: no target/capabilities, `.skip`, `.unbound`, nil timestamp.
    pub fn new(id: String, abstract_role: impl Into<String>) -> Self {
        Binding {
            id,
            abstract_role: abstract_role.into(),
            resolved_target: None,
            required_capabilities: Vec::new(),
            fallback_strategy: BindingFallbackStrategy::Skip,
            resolution_status: BindingResolutionStatus::Unbound,
            resolved_at: None,
        }
    }

    pub fn generate(abstract_role: impl Into<String>) -> Self {
        Self::new(new_uuid(), abstract_role)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OverrideTargetKind {
    #[serde(rename = "scene_instance")]
    SceneInstance,
    #[serde(rename = "component_field")]
    ComponentField,
    #[serde(rename = "material_param")]
    MaterialParam,
    #[serde(rename = "light_param")]
    LightParam,
    #[serde(rename = "camera_param")]
    CameraParam,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OverrideValueKind {
    Absolute,
    Additive,
    Multiplicative,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipEase {
    Linear,
    #[serde(rename = "ease_in")]
    EaseIn,
    #[serde(rename = "ease_out")]
    EaseOut,
    #[serde(rename = "ease_in_out")]
    EaseInOut,
    Step,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShotOverride {
    pub id: String,
    pub target_kind: OverrideTargetKind,
    pub target_ref: SceneTargetReference,
    pub value_kind: OverrideValueKind,
    pub value: SequenceValue,
    pub blend_in_frames: i64,
    pub blend_out_frames: i64,
    pub ease: ClipEase,
    pub source: SequenceProvenance,
    pub proposal_id: Option<String>,
}

impl ShotOverride {
    /// Swift defaults: absolute, no blends, linear, authored, no proposal.
    pub fn new(
        id: String,
        target_kind: OverrideTargetKind,
        target_ref: SceneTargetReference,
        value: SequenceValue,
    ) -> Self {
        ShotOverride {
            id,
            target_kind,
            target_ref,
            value_kind: OverrideValueKind::Absolute,
            value,
            blend_in_frames: 0,
            blend_out_frames: 0,
            ease: ClipEase::Linear,
            source: SequenceProvenance::Authored,
            proposal_id: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MarkerKind {
    Chapter,
    Note,
    #[serde(rename = "sync_point")]
    SyncPoint,
    #[serde(rename = "render_split")]
    RenderSplit,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Marker {
    pub id: String,
    pub frame: i64,
    pub kind: MarkerKind,
    pub label: String,
    pub color_token: String,
}

impl Marker {
    /// Swift default: `colorToken: ""`.
    #[inline]
    pub fn new(id: String, frame: i64, kind: MarkerKind, label: impl Into<String>) -> Self {
        Marker { id, frame, kind, label: label.into(), color_token: String::new() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CutTransition {
    Hard,
    Dissolve,
    #[serde(rename = "fade_in")]
    FadeIn,
    #[serde(rename = "fade_out")]
    FadeOut,
    Wipe,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cut {
    pub id: String,
    pub frame: i64,
    pub transition: CutTransition,
    pub duration: i64,
    pub params: std::collections::BTreeMap<String, SequenceValue>,
}

impl Cut {
    /// Swift defaults: duration 0, empty params.
    #[inline]
    pub fn new(id: String, frame: i64, transition: CutTransition) -> Self {
        Cut { id, frame, transition, duration: 0, params: std::collections::BTreeMap::new() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShotStatus {
    Planning,
    Blocking,
    Lighting,
    Rendering,
    Final,
    Locked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackKind {
    Animation,
    Camera,
    Audio,
    Event,
    Subscene,
    Fx,
    Lighting,
    #[serde(rename = "post_process")]
    PostProcess,
    Data,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ClipPayload {
    pub metadata: std::collections::BTreeMap<String, SequenceValue>,
}

impl ClipPayload {
    #[inline]
    pub fn new(metadata: std::collections::BTreeMap<String, SequenceValue>) -> Self {
        ClipPayload { metadata }
    }

    /// Swift's `subscript(key:)`.
    #[inline]
    pub fn get(&self, key: &str) -> Option<&SequenceValue> {
        self.metadata.get(key)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    pub id: String,
    pub name: String,
    pub shot_range: FrameRange,
    pub source_offset: i64,
    pub time_warp: f64,
    pub enabled: bool,
    pub blend_in_frames: i64,
    pub blend_out_frames: i64,
    pub ease: ClipEase,
    pub weight: f64,
    pub bindings: Vec<Binding>,
    pub payload: ClipPayload,
    pub provenance: SequenceProvenance,
}

impl Clip {
    /// Swift defaults: offset 0, warp 1, enabled, no blends, linear, weight 1,
    /// no bindings, empty payload, authored.
    pub fn new(id: String, name: impl Into<String>, shot_range: FrameRange) -> Self {
        Clip {
            id,
            name: name.into(),
            shot_range,
            source_offset: 0,
            time_warp: 1.0,
            enabled: true,
            blend_in_frames: 0,
            blend_out_frames: 0,
            ease: ClipEase::Linear,
            weight: 1.0,
            bindings: Vec::new(),
            payload: ClipPayload::default(),
            provenance: SequenceProvenance::Authored,
        }
    }
}

/// A track. `solo` and `lock` are session state: Swift's `CodingKeys` omit them,
/// so they never appear in the persisted JSON.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Track {
    pub id: String,
    pub name: String,
    pub kind: TrackKind,
    pub mute: bool,
    #[serde(skip)]
    pub solo: bool,
    #[serde(skip)]
    pub lock: bool,
    #[serde(rename = "color_token")]
    pub color_token: String,
    pub clips: Vec<Clip>,
    pub group: Option<String>,
}

impl Track {
    /// Swift defaults: not muted, no solo/lock, empty colour token, no clips/group.
    pub fn new(id: String, name: impl Into<String>, kind: TrackKind) -> Self {
        Track {
            id,
            name: name.into(),
            kind,
            mute: false,
            solo: false,
            lock: false,
            color_token: String::new(),
            clips: Vec::new(),
            group: None,
        }
    }
}

/// Decodes exactly the keys `Track`'s `CodingKeys` declare; `solo`/`lock` stay false.
impl<'de> Deserialize<'de> for Track {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Track, D::Error> {
        #[derive(Deserialize)]
        struct TrackFields {
            id: String,
            name: String,
            kind: TrackKind,
            mute: bool,
            #[serde(rename = "color_token")]
            color_token: String,
            clips: Vec<Clip>,
            group: Option<String>,
        }

        let fields = TrackFields::deserialize(deserializer)?;
        Ok(Track {
            id: fields.id,
            name: fields.name,
            kind: fields.kind,
            mute: fields.mute,
            solo: false,
            lock: false,
            color_token: fields.color_token,
            clips: fields.clips,
            group: fields.group,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shot {
    pub id: String,
    pub name: String,
    pub range: FrameRange,
    pub source_offset: i64,
    pub camera_binding: Binding,
    pub default_scene_view: Option<SceneTargetReference>,
    pub overrides: Vec<ShotOverride>,
    pub tracks: Vec<Track>,
    pub notes: Option<String>,
    pub status: ShotStatus,
    pub provenance: SequenceProvenance,
    pub revision: SequenceRevision,
}

impl Shot {
    /// Swift defaults: offset 0, no view/overrides/tracks/notes, `.planning`,
    /// authored, fresh revision.
    pub fn new(
        id: String,
        name: impl Into<String>,
        range: FrameRange,
        camera_binding: Binding,
    ) -> Self {
        Shot {
            id,
            name: name.into(),
            range,
            source_offset: 0,
            camera_binding,
            default_scene_view: None,
            overrides: Vec::new(),
            tracks: Vec::new(),
            notes: None,
            status: ShotStatus::Planning,
            provenance: SequenceProvenance::Authored,
            revision: SequenceRevision::generate(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SequenceResolution {
    pub width: i64,
    pub height: i64,
}

impl SequenceResolution {
    #[inline]
    pub const fn new(width: i64, height: i64) -> Self {
        SequenceResolution { width, height }
    }

    /// Swift's `hd1080`.
    pub const HD1080: SequenceResolution = SequenceResolution { width: 1920, height: 1080 };
}

impl Default for SequenceResolution {
    fn default() -> Self {
        Self::HD1080
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AspectRatio {
    pub width: i64,
    pub height: i64,
}

impl AspectRatio {
    #[inline]
    pub const fn new(width: i64, height: i64) -> Self {
        AspectRatio { width, height }
    }

    /// Swift's `widescreen`.
    pub const WIDESCREEN: AspectRatio = AspectRatio { width: 16, height: 9 };
}

impl Default for AspectRatio {
    fn default() -> Self {
        Self::WIDESCREEN
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MotionBlurSettings {
    pub shutter_angle_degrees: f32,
    pub samples: i64,
}

impl MotionBlurSettings {
    #[inline]
    pub const fn new(shutter_angle_degrees: f32, samples: i64) -> Self {
        MotionBlurSettings { shutter_angle_degrees, samples }
    }

    /// Swift default: 180° with one sample.
    pub const DEFAULT: MotionBlurSettings =
        MotionBlurSettings { shutter_angle_degrees: 180.0, samples: 1 };
}

impl Default for MotionBlurSettings {
    fn default() -> Self {
        Self::DEFAULT
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SequenceCacheKind {
    Physics,
    Cloth,
    Fluid,
    Hair,
    Gi,
    Particle,
    #[serde(rename = "render_proxy")]
    RenderProxy,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SequenceCacheInvalidationPolicy {
    Strict,
    Tolerant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SequenceCacheHitStrategy {
    Exact,
    #[serde(rename = "nearest_frame")]
    NearestFrame,
    Interpolate,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceCache {
    pub id: String,
    pub kind: SequenceCacheKind,
    pub shot_id: String,
    pub clip_id: Option<String>,
    pub range: FrameRange,
    pub storage_uri: String,
    pub source_revision: SequenceRevision,
    pub invalidation_policy: SequenceCacheInvalidationPolicy,
    pub hit_strategy: SequenceCacheHitStrategy,
}

impl SequenceCache {
    /// Swift defaults: no clip, strict invalidation, exact hits.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        kind: SequenceCacheKind,
        shot_id: impl Into<String>,
        clip_id: Option<String>,
        range: FrameRange,
        storage_uri: impl Into<String>,
        source_revision: SequenceRevision,
    ) -> Self {
        SequenceCache {
            id,
            kind,
            shot_id: shot_id.into(),
            clip_id,
            range,
            storage_uri: storage_uri.into(),
            source_revision,
            invalidation_policy: SequenceCacheInvalidationPolicy::Strict,
            hit_strategy: SequenceCacheHitStrategy::Exact,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SequenceDocument {
    pub id: String,
    pub name: String,
    pub scene_document_uri: String,
    pub time_base: TimeBase,
    pub frame_range: FrameRange,
    pub resolution: SequenceResolution,
    pub aspect_ratio: AspectRatio,
    pub color_space: String,
    pub motion_blur: MotionBlurSettings,
    pub shots: Vec<Shot>,
    pub markers: Vec<Marker>,
    pub cuts: Vec<Cut>,
    pub caches: Vec<SequenceCache>,
    pub evaluation_policy: SequenceEvaluationPolicy,
    pub provenance: SequenceProvenance,
    pub revision: SequenceRevision,
}

impl SequenceDocument {
    /// Swift defaults: default time base, 1080p, 16:9, `"linear_srgb"`, default
    /// motion blur, empty collections, `.hybrid`, authored, fresh revision.
    pub fn new(
        id: String,
        name: impl Into<String>,
        scene_document_uri: impl Into<String>,
        frame_range: FrameRange,
    ) -> Self {
        SequenceDocument {
            id,
            name: name.into(),
            scene_document_uri: scene_document_uri.into(),
            time_base: TimeBase::default_time_base(),
            frame_range,
            resolution: SequenceResolution::HD1080,
            aspect_ratio: AspectRatio::WIDESCREEN,
            color_space: "linear_srgb".to_string(),
            motion_blur: MotionBlurSettings::DEFAULT,
            shots: Vec::new(),
            markers: Vec::new(),
            cuts: Vec::new(),
            caches: Vec::new(),
            evaluation_policy: SequenceEvaluationPolicy::Hybrid,
            provenance: SequenceProvenance::Authored,
            revision: SequenceRevision::generate(),
        }
    }

    /// First shot whose range contains `sequence_frame`, ordered by range start
    /// then id.
    pub fn shot_containing(&self, sequence_frame: i64) -> Option<&Shot> {
        let mut shots: Vec<&Shot> = self.shots.iter().collect();
        shots.sort_by(|left, right| {
            left.range.start.cmp(&right.range.start).then_with(|| left.id.cmp(&right.id))
        });
        shots.into_iter().find(|shot| shot.range.contains(sequence_frame))
    }

    pub fn markers_at(&self, sequence_frame: i64) -> Vec<&Marker> {
        self.markers.iter().filter(|marker| marker.frame == sequence_frame).collect()
    }

    /// `SequenceDocument+FPS.swift`. Does not mutate the receiver.
    pub fn remapping(
        &self,
        source_fps: i64,
        destination_fps: i64,
        mode: SequenceFPSRemapMode,
    ) -> SequenceDocument {
        remap_sequence_document(self, source_fps, destination_fps, mode)
    }
}
