///! Retained-mode UI node tree.
///!
///! Nodes are stored in a flat pool (arena-allocated) with linked-list
///! tree pointers.  The Canvas owns the pool and drives layout + render.
const std = @import("std");
const style_mod = @import("style.zig");
const layout_mod = @import("layout.zig");

pub const Style = style_mod.Style;
pub const Color = style_mod.Color;
pub const Layout = layout_mod.Layout;
pub const Dimension = layout_mod.Dimension;
pub const Edges = layout_mod.Edges;
pub const ComputedRect = layout_mod.ComputedRect;

pub const NodeTag = enum {
    container,
    text,
    image,
};

pub const EventKind = enum {
    click,
    hover_enter,
    hover_exit,
    pointer_down,
    pointer_up,
};

pub const EventHandler = *const fn (node: *Node, kind: EventKind) void;

pub const Node = struct {
    id: u32,
    tag: NodeTag = .container,

    layout: Layout = .{},
    style: Style = .{},

    /// Computed by the layout engine — do not set manually.
    computed: ComputedRect = .{},

    // ── Tree pointers ───────────────────────────────────────────
    parent: ?u32 = null,
    first_child: ?u32 = null,
    last_child: ?u32 = null,
    next_sibling: ?u32 = null,
    prev_sibling: ?u32 = null,

    // ── Content ─────────────────────────────────────────────────
    text: ?[]const u8 = null,
    texture_id: ?u32 = null,

    // ── State ───────────────────────────────────────────────────
    visible: bool = true,
    interactive: bool = false,
    hovered: bool = false,

    // ── Events ──────────────────────────────────────────────────
    on_event: ?EventHandler = null,

    /// User-provided opaque pointer for callbacks.
    user_data: ?*anyopaque = null,
};

/// Flat pool of nodes with stable u32 indices.
pub const NodePool = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    free_list: std.ArrayListUnmanaged(u32) = .empty,
    next_id: u32 = 0,

    pub fn deinit(self: *NodePool, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.free_list.deinit(allocator);
    }

    pub fn alloc(self: *NodePool, allocator: std.mem.Allocator) !*Node {
        const id: u32 = blk: {
            if (self.free_list.items.len > 0) {
                const recycled = self.free_list.items[self.free_list.items.len - 1];
                self.free_list.items.len -= 1;
                break :blk recycled;
            }
            const fresh = self.next_id;
            self.next_id += 1;
            try self.nodes.append(allocator, undefined_node(fresh));
            break :blk fresh;
        };
        const node = &self.nodes.items[@intCast(id)];
        node.* = .{ .id = id };
        return node;
    }

    pub fn free(self: *NodePool, allocator: std.mem.Allocator, id: u32) void {
        if (id >= self.nodes.items.len) return;
        self.nodes.items[@intCast(id)] = undefined_node(id);
        self.free_list.append(allocator, id) catch {};
    }

    pub fn get(self: *NodePool, id: u32) ?*Node {
        if (id >= self.nodes.items.len) return null;
        return &self.nodes.items[@intCast(id)];
    }

    fn undefined_node(id: u32) Node {
        return .{
            .id = id,
            .visible = false,
        };
    }
};

/// Tree manipulation helpers that operate on a NodePool.
pub const Tree = struct {
    pool: *NodePool,

    pub fn appendChild(self: Tree, parent_id: u32, child_id: u32) void {
        const parent = self.pool.get(parent_id) orelse return;
        const child = self.pool.get(child_id) orelse return;

        child.parent = parent_id;
        child.next_sibling = null;
        child.prev_sibling = parent.last_child;

        if (parent.last_child) |last_id| {
            if (self.pool.get(last_id)) |last| {
                last.next_sibling = child_id;
            }
        } else {
            parent.first_child = child_id;
        }
        parent.last_child = child_id;
    }

    pub fn removeChild(self: Tree, child_id: u32) void {
        const child = self.pool.get(child_id) orelse return;
        const parent_id = child.parent orelse return;
        const parent = self.pool.get(parent_id) orelse return;

        if (child.prev_sibling) |prev_id| {
            if (self.pool.get(prev_id)) |prev| {
                prev.next_sibling = child.next_sibling;
            }
        } else {
            parent.first_child = child.next_sibling;
        }

        if (child.next_sibling) |next_id| {
            if (self.pool.get(next_id)) |next| {
                next.prev_sibling = child.prev_sibling;
            }
        } else {
            parent.last_child = child.prev_sibling;
        }

        child.parent = null;
        child.prev_sibling = null;
        child.next_sibling = null;
    }

    /// Recursively free a node and all its descendants.
    pub fn destroySubtree(self: Tree, allocator: std.mem.Allocator, node_id: u32) void {
        const node = self.pool.get(node_id) orelse return;
        // Recurse children
        var child_opt = node.first_child;
        while (child_opt) |cid| {
            const next = if (self.pool.get(cid)) |c| c.next_sibling else null;
            self.destroySubtree(allocator, cid);
            child_opt = next;
        }
        // Detach from parent
        self.removeChild(node_id);
        self.pool.free(allocator, node_id);
    }

    // ── Layout engine interface ─────────────────────────────────
    // These methods match the interface expected by layout_mod.computeLayout.

    pub fn firstChild(self: Tree, id: usize) ?usize {
        const node = self.pool.get(@intCast(id)) orelse return null;
        return if (node.first_child) |c| @as(usize, c) else null;
    }

    pub fn nextSibling(self: Tree, id: usize) ?usize {
        const node = self.pool.get(@intCast(id)) orelse return null;
        return if (node.next_sibling) |s| @as(usize, s) else null;
    }

    pub fn nodeLayout(self: Tree, id: usize) *Layout {
        const node = self.pool.get(@intCast(id)) orelse unreachable;
        return &node.layout;
    }

    pub fn nodeComputed(self: Tree, id: usize) *ComputedRect {
        const node = self.pool.get(@intCast(id)) orelse unreachable;
        return &node.computed;
    }
};
