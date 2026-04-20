///! editor_rpc/settings.zig — shared editor settings.
///!
///! Central settings struct replacing the scattered module-level `var`
///! declarations that used to live in individual handler files.  Owned by
///! the RPC Server and passed to handlers through `Ctx.settings`.
///!
///! Eventually `editor_backend/EditorState` can embed or reference this
///! struct to eliminate the remaining state duplication between the two
///! execution modes (editor-server vs. MCP).
const schema_types = @import("schema/types.zig");

pub const EditorSettings = struct {
    viewport: ViewportSettings = .{},
    physics_viz: PhysicsVizSettings = .{},
    camera: CameraState = .{},
    material: MaterialSettings = .{},

    // ── Viewport & Render Output ────────────────────────────────

    pub const ViewportSettings = struct {
        shading_mode: schema_types.ViewportShadingMode = .rendered,
        transform_space: schema_types.TransformSpace = .local,
        show_grid: bool = true,
        show_bones: bool = false,
        show_collision: bool = false,
        pt_samples: u32 = 12,
        pt_bounces: u32 = 4,
        pt_resolution_scale: f32 = 1.0,
        render_output: RenderOutput = .{},
    };

    pub const RenderOutput = struct {
        preset: ResolutionPreset = .hd_1080,
        width: u32 = 1920,
        height: u32 = 1080,
        format: OutputFormat = .png,
        path: [256]u8 = [_]u8{0} ** 256,
        path_len: usize = 0,
    };

    pub const ResolutionPreset = enum { viewport, hd_1080, dci_2k, uhd_4k, custom };
    pub const OutputFormat = enum { png, exr, jpg };

    // ── Physics Debug Visualization ─────────────────────────────

    pub const PhysicsVizSettings = struct {
        draw_mode: DrawMode = .off,
        opacity: f32 = 0.8,
        velocity_scale: f32 = 1.0,
        wireframe_only: bool = true,
        show_collision_shapes: bool = true,
        show_rigidbodies: bool = true,
        show_triggers: bool = true,
        show_constraints: bool = false,
        show_velocity_vectors: bool = false,
        show_sleep_state: bool = false,
        show_aabbs: bool = false,
        color_static: [4]f32 = .{ 0.0, 0.8, 0.0, 0.8 },
        color_dynamic: [4]f32 = .{ 0.0, 0.4, 1.0, 0.8 },
        color_kinematic: [4]f32 = .{ 1.0, 0.5, 0.0, 0.8 },
        color_trigger: [4]f32 = .{ 1.0, 1.0, 0.0, 0.5 },
        color_sleeping: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 },
        color_constraint: [4]f32 = .{ 1.0, 0.0, 1.0, 0.8 },
    };

    pub const DrawMode = enum { off, selection_only, all };

    // ── Camera Bookmarks ────────────────────────────────────────

    pub const CameraState = struct {
        bookmark_buf: [max_bookmarks]Bookmark = undefined,
        bookmark_len: usize = 0,

        pub const max_bookmarks = 64;
    };

    pub const Bookmark = struct {
        name: [64]u8 = [_]u8{0} ** 64,
        name_len: usize = 0,
        translation: [3]f32 = .{ 0, 0, 0 },
        rotation: [4]f32 = .{ 0, 0, 0, 1 }, // quaternion xyzw
        fov: f32 = 1.0471976, // ~60 degrees in radians

        pub fn getName(self: *const Bookmark) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    // ── Material Preview ────────────────────────────────────────

    pub const MaterialSettings = struct {
        preview_primitive: PreviewPrimitive = .sphere,
    };

    pub const PreviewPrimitive = enum { sphere, plane };
};
