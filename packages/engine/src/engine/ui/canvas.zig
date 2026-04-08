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
const node_mod = @import("node.zig");
const layout_mod = @import("layout.zig");
const renderer_mod = @import("renderer.zig");
const font_mod = @import("font.zig");
const rhi_mod = @import("../rhi/device.zig");

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

    pub fn deinit(self: *Canvas, device: *rhi_mod.RhiDevice) void {
        if (self.font) |*f| f.deinit(device);
        if (self.font_data) |d| self.allocator.free(d);
        self.renderer.deinit(device);
        self.pool.deinit(self.allocator);
    }

    pub fn createGpuResources(self: *Canvas, device: *rhi_mod.RhiDevice) !void {
        try self.renderer.createGpuResources(device);
    }

    /// Load a TTF font from a file path and create the SDF atlas on the GPU.
    pub fn loadFont(self: *Canvas, device: *rhi_mod.RhiDevice, path: []const u8, font_size_px: f32) !void {
        // Read font file
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        const data = try self.allocator.alloc(u8, stat.size);
        const bytes_read = try file.readAll(data);
        if (bytes_read != stat.size) {
            self.allocator.free(data);
            return error.IncompleteRead;
        }
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
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
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
};
