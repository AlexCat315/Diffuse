///! UICanvas — the public API for runtime game UI.
///!
///! Each viewport owns one Canvas. The canvas holds a retained node tree,
///! drives layout computation, and forwards draw data to the UIRenderer.
///!
///! Usage from game scripts:
///!
///!   const panel = try canvas.createNode(.container);
///!   panel.layout.width = .{ .percent = 100 };
///!   panel.layout.height = .{ .px = 48 };
///!   panel.style.background = Color.hex(0x1a1a2e).withAlpha(0.85);
///!
///!   const label = try canvas.createNode(.text);
///!   label.text = "HP: 100";
///!   label.style.text_color = Color.green;
///!   canvas.appendChild(panel.id, label.id);
///!   canvas.appendToRoot(panel.id);
///!
const std = @import("std");
const io_globals = @import("io_globals");
const node_mod = @import("node.zig");
const layout_mod = @import("layout.zig");
const renderer_mod = @import("renderer.zig");
const font_mod = @import("font.zig");
const gfx_mod = @import("gfx/mod.zig");

pub const Node = node_mod.Node;
pub const NodeTag = node_mod.NodeTag;
pub const Style = node_mod.Style;
pub const Color = node_mod.Color;
pub const Layout = node_mod.Layout;
pub const Dimension = node_mod.Dimension;
pub const Edges = node_mod.Edges;
pub const ComputedRect = node_mod.ComputedRect;
pub const EventKind = node_mod.EventKind;
pub const UIRenderer = renderer_mod.UIRenderer;
pub const UIVertex = renderer_mod.UIVertex;
pub const Font = font_mod.Font;

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    pool: node_mod.NodePool = .{},
    tree: node_mod.Tree = undefined,
    root_id: u32 = 0,
    renderer: UIRenderer,
    font: ?font_mod.Font = null,
    font_data: ?[]u8 = null, // owned TTF bytes
    dirty: bool = true,
    debug_hud_id: ?u32 = null,
    debug_fps_id: ?u32 = null,
    debug_draw_id: ?u32 = null,
    debug_entity_id: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) !Canvas {
        var canvas = Canvas{
            .allocator = allocator,
            .renderer = UIRenderer.init(allocator),
        };
        canvas.tree = .{ .pool = &canvas.pool };
        // Create root node (fills the viewport)
        const root = try canvas.pool.alloc(allocator);
        root.tag = .container;
        root.layout.width = .{ .percent = 100 };
        root.layout.height = .{ .percent = 100 };
        root.visible = true;
        canvas.root_id = root.id;
        return canvas;
    }

    pub fn deinit(self: *Canvas, device: *gfx_mod.GfxDevice) void {
        if (self.font) |*f| f.deinit(device);
        if (self.font_data) |d| self.allocator.free(d);
        self.renderer.deinit(device);
        self.pool.deinit(self.allocator);
    }

    pub fn createGpuResources(self: *Canvas, device: *gfx_mod.GfxDevice) !void {
        try self.renderer.createGpuResources(device);
    }

    /// Load a TTF font from a file path and create the SDF atlas on the GPU.
    pub fn loadFont(self: *Canvas, device: *gfx_mod.GfxDevice, path: []const u8, font_size_px: f32) !void {
        // Read font file
        const io = io_globals.global_io;
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .unlimited);
        self.font_data = data;

        // Initialize font and generate atlas
        self.font = font_mod.Font.init(self.allocator);
        const ascii_range = [_][2]u32{.{ 32, 126 }}; // printable ASCII
        try self.font.?.load(data, font_size_px, &ascii_range);
        try self.font.?.createGpuResources(device);

        // Wire font into renderer
        self.renderer.font = &self.font.?;
    }

    // ── Node CRUD ───────────────────────────────────────────────

    pub fn createNode(self: *Canvas, tag: NodeTag) !*Node {
        self.dirty = true;
        const n = try self.pool.alloc(self.allocator);
        n.tag = tag;
        return n;
    }

    pub fn destroyNode(self: *Canvas, id: u32) void {
        self.dirty = true;
        self.tree.destroySubtree(self.allocator, id);
    }

    pub fn getNode(self: *Canvas, id: u32) ?*Node {
        return self.pool.get(id);
    }

    // ── Tree manipulation ───────────────────────────────────────

    pub fn appendChild(self: *Canvas, parent_id: u32, child_id: u32) void {
        self.dirty = true;
        self.tree.appendChild(parent_id, child_id);
    }

    pub fn appendToRoot(self: *Canvas, child_id: u32) void {
        self.appendChild(self.root_id, child_id);
    }

    pub fn removeFromParent(self: *Canvas, child_id: u32) void {
        self.dirty = true;
        self.tree.removeChild(child_id);
    }

    // ── Layout + Render ─────────────────────────────────────────

    pub fn update(self: *Canvas, viewport_w: f32, viewport_h: f32) void {
        // Always recompute layout (nodes may have updated properties)
        layout_mod.computeLayout(
            node_mod.Tree,
            &self.tree,
            @as(usize, self.root_id),
            0,
            0,
            viewport_w,
            viewport_h,
        );

        // Build render geometry from tree
        self.renderer.buildFromTree(&self.pool, self.root_id);
        self.dirty = false;
    }

    pub fn draw(
        self: *Canvas,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        viewport_w: f32,
        viewport_h: f32,
    ) void {
        self.renderer.flush(device, frame, pass, viewport_w, viewport_h);
    }

    // ── Hit testing ─────────────────────────────────────────────

    /// Find the deepest interactive node under (px, py).
    pub fn hitTest(self: *Canvas, px: f32, py: f32) ?*Node {
        return self.hitTestNode(self.root_id, px, py);
    }

    fn hitTestNode(self: *Canvas, id: u32, px: f32, py: f32) ?*Node {
        const node = self.pool.get(id) orelse return null;
        if (!node.visible) return null;
        if (!node.computed.contains(px, py)) return null;

        // Check children in reverse order (front-to-back)
        var deepest: ?*Node = null;
        var child_opt = node.last_child;
        while (child_opt) |cid| {
            if (self.hitTestNode(cid, px, py)) |hit| {
                deepest = hit;
                break;
            }
            child_opt = if (self.pool.get(cid)) |c| c.prev_sibling else null;
        }

        if (deepest) |d| return d;
        if (node.interactive) return node;
        return null;
    }

    // ── Convenience builders ────────────────────────────────────

    /// Process mouse input for hover and click detection.
    /// Call once per frame, after input polling and before script updates.
    pub fn processInput(self: *Canvas, mouse_x: f32, mouse_y: f32, left_pressed: bool, left_released: bool) void {
        // Clear per-frame state on all interactive nodes.
        for (self.pool.nodes.items) |*n| {
            if (n.hovered or n.clicked_this_frame) {
                if (n.hovered) {
                    if (n.on_event) |handler| handler(n, .hover_exit);
                }
                n.hovered = false;
                n.clicked_this_frame = false;
            }
        }

        // Hit-test under cursor → mark hovered chain.
        if (self.hitTest(mouse_x, mouse_y)) |hit| {
            var cur: ?*Node = hit;
            while (cur) |n| {
                n.hovered = true;
                if (n.on_event) |handler| handler(n, .hover_enter);
                cur = if (n.parent) |pid| self.pool.get(pid) else null;
            }

            // Left button press fires click on the deepest interactive node.
            if (left_pressed and hit.interactive) {
                hit.clicked_this_frame = true;
                if (hit.on_event) |handler| handler(hit, .click);
            }
        }

        _ = left_released; // reserved for future pointer_up events
    }

    pub fn addPanel(self: *Canvas, opts: struct {
        parent: ?u32 = null,
        x: ?f32 = null,
        y: ?f32 = null,
        width: Dimension = .auto,
        height: Dimension = .auto,
        background: Color = Color.transparent,
        border_radius: f32 = 0,
        padding: f32 = 0,
    }) !*Node {
        const n = try self.createNode(.container);
        n.layout.width = opts.width;
        n.layout.height = opts.height;
        n.layout.padding = Edges.uniform(opts.padding);
        n.style.background = opts.background;
        n.style.border_radius = opts.border_radius;
        if (opts.x != null or opts.y != null) {
            n.layout.position = .absolute;
            n.layout.anchor_left = opts.x;
            n.layout.anchor_top = opts.y;
        }
        if (opts.parent) |pid| {
            self.appendChild(pid, n.id);
        } else {
            self.appendToRoot(n.id);
        }
        return n;
    }

    pub fn addLabel(self: *Canvas, opts: struct {
        parent: ?u32 = null,
        text: []const u8 = "",
        color: Color = Color.white,
        font_size: f32 = 16,
    }) !*Node {
        const n = try self.createNode(.text);
        n.tag = .text;
        n.text = opts.text;
        n.style.text_color = opts.color;
        n.style.font_size = opts.font_size;
        // Auto-size based on font
        n.layout.height = .{ .px = opts.font_size * 1.2 };
        if (opts.parent) |pid| {
            self.appendChild(pid, n.id);
        }
        return n;
    }

    // ── Debug HUD ───────────────────────────────────────────────

    /// 格式化整数到固定缓冲区（避免分配）
    fn fmtInt(buf: []u8, prefix: []const u8, value: usize) []const u8 {
        var pos: usize = 0;
        for (prefix) |c| {
            if (pos >= buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
        // 简化整数格式化
        if (value == 0) {
            if (pos < buf.len) {
                buf[pos] = '0';
                pos += 1;
            }
        } else {
            var tmp: [20]u8 = undefined;
            var ti: usize = 0;
            var v = value;
            while (v > 0) : (ti += 1) {
                tmp[ti] = @intCast('0' + (v % 10));
                v /= 10;
            }
            var i: usize = 0;
            while (i < ti and pos < buf.len) : (i += 1) {
                buf[pos] = tmp[ti - 1 - i];
                pos += 1;
            }
        }
        return buf[0..pos];
    }

    /// 每帧更新 debug HUD 文本。由 Renderer 在 update() 之前调用。
    pub fn updateDebugHud(self: *Canvas, fps: usize, draw_calls: usize, entity_count: usize) void {
        // 延迟创建 HUD 节点（首次调用时）
        if (self.debug_hud_id == null) {
            const panel = self.addPanel(.{
                .x = 8,
                .y = 8,
                .width = .{ .px = 180 },
                .height = .{ .px = 64 },
                .background = Color{ .r = 0.05, .g = 0.05, .b = 0.1, .a = 0.75 },
                .border_radius = 4,
                .padding = 6,
            }) catch return;
            self.debug_hud_id = panel.id;

            const fps_lbl = self.addLabel(.{ .parent = panel.id, .text = "FPS: --", .color = Color.green, .font_size = 14 }) catch return;
            self.debug_fps_id = fps_lbl.id;

            const draw_lbl = self.addLabel(.{ .parent = panel.id, .text = "Draw: --", .color = Color.white, .font_size = 14 }) catch return;
            self.debug_draw_id = draw_lbl.id;

            const ent_lbl = self.addLabel(.{ .parent = panel.id, .text = "Ent: --", .color = Color.white, .font_size = 14 }) catch return;
            self.debug_entity_id = ent_lbl.id;
        }

        // 更新文字
        var fps_buf: [32]u8 = undefined;
        var draw_buf: [32]u8 = undefined;
        var ent_buf: [32]u8 = undefined;

        if (self.pool.get(self.debug_fps_id.?)) |n| {
            n.text = fmtInt(&fps_buf, "FPS: ", fps);
            n.style.text_color = if (fps >= 55) Color.green else if (fps >= 30) Color.yellow else Color.red;
        }
        if (self.pool.get(self.debug_draw_id.?)) |n| {
            n.text = fmtInt(&draw_buf, "Draw: ", draw_calls);
        }
        if (self.pool.get(self.debug_entity_id.?)) |n| {
            n.text = fmtInt(&ent_buf, "Entities: ", entity_count);
        }
        self.dirty = true;
    }
};
