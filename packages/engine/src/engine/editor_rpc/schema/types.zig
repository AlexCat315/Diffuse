///! Shared data types for the editor–engine RPC contract.
///!
///! This is the SINGLE source of truth for transport-level types used across
///! the RPC schema, handlers, and editor_backend.  Zero engine imports.

// ── Geometry ──────────────────────────────────────────────────────

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Quat = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub const Transform = struct {
    position: Vec3,
    rotation: Quat,
    scale: Vec3,
};

pub const TransformPartial = struct {
    position: ?Vec3 = null,
    rotation: ?Quat = null,
    scale: ?Vec3 = null,
};

// ── Scene / ECS ───────────────────────────────────────────────────

pub const EntityNode = struct {
    id: u64,
    name: []const u8,
    visible: bool,
    selectable: bool,
    children: []const EntityNode,
};

pub const ComponentInfo = struct {
    type: []const u8,
    fields: []const ComponentField,
};

pub const ComponentField = struct {
    name: []const u8,
    fieldType: []const u8,
    value: JsonValue,
    options: ?[]const []const u8 = null,
};

/// Opaque JSON value — codegen emits this as `unknown`.
pub const JsonValue = struct { _opaque: u8 = 0 };

// ── Console ───────────────────────────────────────────────────────

pub const LogEntry = struct {
    level: []const u8,
    message: []const u8,
    timestamp: f64,
    source: ?[]const u8 = null,
};

// ── Assets ────────────────────────────────────────────────────────

pub const AssetEntry = struct {
    name: []const u8,
    path: []const u8,
    isDirectory: bool,
    assetType: ?[]const u8 = null,
    size: ?u64 = null,
};

pub const ScriptFileInfo = struct {
    path: []const u8,
    name: []const u8,
    language: []const u8,
    sizeBytes: u64,
};

// ── Sequencer ─────────────────────────────────────────────────────

pub const SequencerTrack = struct {
    index: u64,
    kind: []const u8,
    target: []const u8,
};

// ── Animation ─────────────────────────────────────────────────────

pub const AnimGraphState = struct {
    index: u64,
    name: []const u8,
    clipName: ?[]const u8 = null,
    speed: f64,
    loop: bool,
    duration: f64,
    isDefault: bool,
    isCurrent: bool,
    isNext: bool,
};

pub const AnimGraphTransition = struct {
    index: u64,
    fromState: u64,
    toState: u64,
    fromStateName: []const u8,
    toStateName: []const u8,
    duration: f64,
    conditions: []const AnimTransitionCondition,
};

pub const AnimTransitionCondition = struct {
    index: u64,
    conditionType: []const u8,
    threshold: f64,
    parameterName: ?[]const u8 = null,
    comparison: ?[]const u8 = null,
};

pub const AnimGraphParameter = struct {
    index: u64,
    name: []const u8,
    paramType: []const u8,
    floatValue: ?f64 = null,
    boolValue: ?bool = null,
    intValue: ?i64 = null,
};

pub const AnimClipTrack = struct {
    index: u64,
    name: []const u8,
    trackType: []const u8,
    keyframeCount: u64,
};

// ── Material graph ────────────────────────────────────────────────

pub const MaterialGraphNodeInfo = struct {
    id: u32,
    kind: []const u8,
    outputType: []const u8,
    channel: ?[]const u8 = null,
    valueKind: []const u8,
    scalar: f64,
    vec2: [2]f64,
    vec3: [3]f64,
    vec4: [4]f64,
    textureHandle: ?u32 = null,
    posX: f64,
    posY: f64,
};

pub const MaterialGraphConnectionInfo = struct {
    fromNodeId: u32,
    fromSlot: u8,
    toNodeId: u32,
    toSlot: u8,
};

pub const MaterialGraphOutputInfo = struct {
    channel: []const u8,
    sourceNodeId: u32,
    sourceSlot: u8,
};

// ── VFX / Particle ────────────────────────────────────────────────

pub const VfxEntityInfo = struct {
    entityId: u64,
    name: []const u8,
    kind: []const u8,
};

pub const VfxConfig = struct {
    kind: []const u8,
    looping: bool,
    emissionRate: f64,
    particleLifetime: f64,
    speed: f64,
    maxParticles: u32,
    radius: f64,
    spread: f64,
    size: f64,
    colorR: f64,
    colorG: f64,
    colorB: f64,
};

// ── Prefab ────────────────────────────────────────────────────────

pub const PrefabInfo = struct {
    id: []const u8,
    name: []const u8,
    version: u32,
    entityCount: u32,
    sourcePath: ?[]const u8 = null,
};

pub const PrefabEntityNode = struct {
    prefabEntityId: u32,
    name: []const u8,
    parentId: ?u32 = null,
    visible: bool,
    isFolder: bool,
    hasTransform: bool,
    hasMesh: bool,
    hasMaterial: bool,
    hasLight: bool,
    hasCamera: bool,
    hasScript: bool,
    hasVfx: bool,
};

pub const PrefabEntityDetail = struct {
    prefabEntityId: u32,
    name: []const u8,
    visible: bool,
    isFolder: bool,
    posX: f64,
    posY: f64,
    posZ: f64,
    rotX: f64,
    rotY: f64,
    rotZ: f64,
    rotW: f64,
    scaleX: f64,
    scaleY: f64,
    scaleZ: f64,
    components: []const []const u8,
};

// ── Shared enums (canonical definitions) ──────────────────────────

pub const ManipulationMode = enum {
    none,
    translate,
    rotate,
    scale,
};

pub const TransformSpace = enum {
    local,
    world,
};

pub const ViewportShadingMode = enum {
    solid,
    material,
    rendered,
    wireframe,
};

pub const RenderJobStatus = enum {
    queued,
    rendering,
    complete,
    failed,
};
