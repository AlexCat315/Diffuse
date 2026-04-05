///! Cross-module mesh editing interface.
///!
///! Defines the vtable used by editor_rpc handlers and subscriptions
///! to interact with mesh editing logic.  The actual implementations
///! live in the root module (mesh_bridge.zig) and are wired up by
///! main.zig, avoiding cross-module @import of editor_backend.
const core = @import("../core/layer.zig");

pub const SelectionMode = enum(u8) { vertex = 0, edge = 1, face = 2 };

pub const Snapshot = struct {
    active: bool = false,
    mode_edit: bool = false, // true = edit, false = object
    selection_mode: SelectionMode = .face,
    selection_count: u32 = 0,
    entity_id: ?u64 = null,
    can_enter_edit_mode: bool = false,
};

/// Virtual function table for mesh editing operations.
/// All function pointers take an opaque `state_ptr` as first arg.
pub const MeshOps = struct {
    state_ptr: *anyopaque,

    // ── State queries ────────────────────────────────────
    getSnapshot: *const fn (state: *anyopaque, layer: *core.LayerContext) Snapshot,

    // ── Mode management ──────────────────────────────────
    enterEditMode: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    exitEditMode: *const fn (state: *anyopaque, layer: *core.LayerContext) void,
    setSelectionMode: *const fn (state: *anyopaque, mode: SelectionMode) void,
    selectEntity: *const fn (state: *anyopaque, layer: *core.LayerContext, entity_id: u64) anyerror!void,

    // ── Mesh operations ──────────────────────────────────
    extrude: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    inset: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    bevel: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    loopCut: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    merge: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    delete: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    duplicate: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    separate: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    recalcNormals: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
    pivotToSelection: *const fn (state: *anyopaque, layer: *core.LayerContext) anyerror!bool,
};
