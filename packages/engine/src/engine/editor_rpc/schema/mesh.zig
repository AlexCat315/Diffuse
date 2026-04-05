///! Mesh editing RPC method schemas.
///!
///! These types are consumed by gen_types.zig to produce the TypeScript
///! interface for the Electron editor.

// ── Mode management ──────────────────────────────────────────────

pub const @"mesh.getState" = struct {
    pub const Params = struct {};
    pub const Result = struct {
        active: bool,
        mode: []const u8, // "object" | "edit"
        selectionMode: []const u8, // "vertex" | "edge" | "face"
        selectionCount: u64,
        canEnterEditMode: bool,
        entityId: ?u64 = null,
    };
};

pub const @"mesh.enterEditMode" = struct {
    pub const Params = struct { entityId: u64 };
    pub const Result = struct { success: bool };
};

pub const @"mesh.exitEditMode" = struct {
    pub const Params = struct {};
    pub const Result = struct {};
};

pub const @"mesh.setSelectionMode" = struct {
    pub const Params = struct { mode: []const u8 }; // "vertex" | "edge" | "face"
    pub const Result = struct {};
};

// ── Mesh operations ──────────────────────────────────────────────

pub const @"mesh.extrude" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.inset" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.bevel" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.loopCut" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.merge" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.delete" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.duplicate" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.separate" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.recalcNormals" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};

pub const @"mesh.pivotToSelection" = struct {
    pub const Params = struct {};
    pub const Result = struct { success: bool };
};
