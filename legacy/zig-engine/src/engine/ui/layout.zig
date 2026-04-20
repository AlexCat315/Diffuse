///! Flexbox-lite layout engine for the retained-mode UI.
const std = @import("std");

pub const Position = enum {
    relative,
    absolute,
};

pub const Direction = enum {
    row,
    column,
};

pub const Align = enum {
    start,
    center,
    end_,
    stretch,
};

pub const Justify = enum {
    start,
    center,
    end_,
    space_between,
    space_around,
};

pub const Dimension = union(enum) {
    auto,
    px: f32,
    percent: f32,

    pub fn resolve(self: Dimension, parent_size: f32) ?f32 {
        return switch (self) {
            .auto => null,
            .px => |v| v,
            .percent => |p| parent_size * p / 100.0,
        };
    }
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn uniform(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }
};

pub const Layout = struct {
    position: Position = .relative,
    direction: Direction = .column,
    align_items: Align = .stretch,
    justify_content: Justify = .start,

    width: Dimension = .auto,
    height: Dimension = .auto,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,

    padding: Edges = .{},
    margin: Edges = .{},
    gap: f32 = 0,

    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,

    /// Absolute positioning offsets (only used when position == .absolute).
    anchor_left: ?f32 = null,
    anchor_top: ?f32 = null,
    anchor_right: ?f32 = null,
    anchor_bottom: ?f32 = null,
};

/// Computed layout result after the layout pass.
pub const ComputedRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: ComputedRect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }

    pub fn right(self: ComputedRect) f32 {
        return self.x + self.width;
    }

    pub fn bottom(self: ComputedRect) f32 {
        return self.y + self.height;
    }
};

// ── Layout computation ──────────────────────────────────────────

const NodeAccessor = struct {
    first_child_fn: *const fn (usize) ?usize,
    next_sibling_fn: *const fn (usize) ?usize,
    layout_fn: *const fn (usize) *Layout,
    computed_fn: *const fn (usize) *ComputedRect,
    child_count_fn: *const fn (usize) u32,
};

/// Compute layout for a subtree rooted at `node_id`.
/// `parent_rect` defines the available space.
pub fn computeLayout(
    comptime Tree: type,
    tree: *Tree,
    node_id: usize,
    parent_x: f32,
    parent_y: f32,
    parent_w: f32,
    parent_h: f32,
) void {
    const layout = tree.nodeLayout(node_id);
    const computed = tree.nodeComputed(node_id);

    // ── Resolve own size ────────────────────────────────────────
    const content_w = clampOpt(
        layout.width.resolve(parent_w) orelse parent_w - layout.margin.horizontal(),
        layout.min_width,
        layout.max_width,
    ) orelse parent_w - layout.margin.horizontal();
    const content_h = clampOpt(
        layout.height.resolve(parent_h) orelse null,
        layout.min_height,
        layout.max_height,
    );

    const inner_w = content_w - layout.padding.horizontal();
    const inner_h = if (content_h) |h| h - layout.padding.vertical() else null;

    // ── Position self ───────────────────────────────────────────
    if (layout.position == .absolute) {
        computed.x = parent_x + (layout.anchor_left orelse 0);
        computed.y = parent_y + (layout.anchor_top orelse 0);
        if (layout.anchor_right) |ar| {
            computed.width = parent_w - (layout.anchor_left orelse 0) - ar;
        } else {
            computed.width = content_w;
        }
        if (layout.anchor_bottom) |ab| {
            computed.height = parent_h - (layout.anchor_top orelse 0) - ab;
        } else {
            computed.height = content_h orelse 0;
        }
    } else {
        computed.x = parent_x + layout.margin.left;
        computed.y = parent_y + layout.margin.top;
        computed.width = content_w;
        computed.height = content_h orelse 0;
    }

    // ── Collect relative children ───────────────────────────────
    var rel_children_buf: [256]usize = undefined;
    var rel_count: usize = 0;
    {
        var child_opt = tree.firstChild(node_id);
        while (child_opt) |cid| {
            const cl = tree.nodeLayout(cid);
            if (cl.position == .relative) {
                if (rel_count < rel_children_buf.len) {
                    rel_children_buf[rel_count] = cid;
                    rel_count += 1;
                }
            }
            child_opt = tree.nextSibling(cid);
        }
    }
    const rel_children = rel_children_buf[0..rel_count];

    // ── Flex layout ─────────────────────────────────────────────
    const is_row = layout.direction == .row;
    const main_available = if (is_row) inner_w else (inner_h orelse 10000);
    const cross_available = if (is_row) (inner_h orelse 10000) else inner_w;

    // First pass: measure natural sizes
    var total_main: f32 = 0;
    var total_grow: f32 = 0;
    var total_shrink: f32 = 0;
    var natural_sizes: [256]f32 = undefined;
    for (rel_children, 0..) |cid, i| {
        const cl = tree.nodeLayout(cid);
        const dim = if (is_row) cl.width else cl.height;
        const main_margin = if (is_row) cl.margin.horizontal() else cl.margin.vertical();
        const natural = (dim.resolve(main_available) orelse 0) + main_margin;
        natural_sizes[i] = natural;
        total_main += natural;
        total_grow += cl.flex_grow;
        total_shrink += cl.flex_shrink;
    }
    if (rel_count > 1) {
        total_main += layout.gap * @as(f32, @floatFromInt(rel_count - 1));
    }

    // Distribute flex space
    const remaining = main_available - total_main;
    var final_sizes: [256]f32 = undefined;
    for (rel_children, 0..) |cid, i| {
        const cl = tree.nodeLayout(cid);
        var size = natural_sizes[i];
        if (remaining > 0 and total_grow > 0) {
            size += remaining * cl.flex_grow / total_grow;
        } else if (remaining < 0 and total_shrink > 0) {
            size += remaining * cl.flex_shrink / total_shrink;
        }
        final_sizes[i] = @max(0, size);
    }

    // ── Justify ─────────────────────────────────────────────────
    var main_cursor = if (is_row)
        computed.x + layout.padding.left
    else
        computed.y + layout.padding.top;

    var gap_between: f32 = layout.gap;
    if (layout.justify_content == .space_between and rel_count > 1) {
        var used: f32 = 0;
        for (0..rel_count) |i| used += final_sizes[i];
        gap_between = (main_available - used) / @as(f32, @floatFromInt(rel_count - 1));
    } else if (layout.justify_content == .space_around and rel_count > 0) {
        var used: f32 = 0;
        for (0..rel_count) |i| used += final_sizes[i];
        gap_between = (main_available - used) / @as(f32, @floatFromInt(rel_count));
        main_cursor += gap_between / 2;
    } else if (layout.justify_content == .center) {
        var used: f32 = 0;
        for (0..rel_count) |i| used += final_sizes[i];
        used += layout.gap * @as(f32, @floatFromInt(if (rel_count > 1) rel_count - 1 else 0));
        main_cursor += (main_available - used) / 2;
    } else if (layout.justify_content == .end_) {
        var used: f32 = 0;
        for (0..rel_count) |i| used += final_sizes[i];
        used += layout.gap * @as(f32, @floatFromInt(if (rel_count > 1) rel_count - 1 else 0));
        main_cursor += main_available - used;
    }

    // ── Place children ──────────────────────────────────────────
    var auto_height: f32 = 0;
    for (rel_children, 0..) |cid, i| {
        const cl = tree.nodeLayout(cid);
        const main_size = final_sizes[i];

        // Cross axis
        const cross_dim = if (is_row) cl.height else cl.width;
        const cross_margin = if (is_row) cl.margin.vertical() else cl.margin.horizontal();
        var cross_size = cross_dim.resolve(cross_available) orelse
            if (layout.align_items == .stretch) cross_available - cross_margin else 0;
        cross_size = @max(0, cross_size);

        const cross_start = if (is_row)
            computed.y + layout.padding.top
        else
            computed.x + layout.padding.left;

        var cross_pos = switch (layout.align_items) {
            .start => cross_start,
            .center => cross_start + (cross_available - cross_size) / 2,
            .end_ => cross_start + cross_available - cross_size,
            .stretch => cross_start,
        };
        _ = &cross_pos;

        const child_x = if (is_row) main_cursor else cross_pos;
        const child_y = if (is_row) cross_pos else main_cursor;
        const child_w = if (is_row) main_size else cross_size;
        const child_h = if (is_row) cross_size else main_size;

        computeLayout(Tree, tree, cid, child_x, child_y, child_w, child_h);

        main_cursor += main_size + gap_between;
        const child_end = if (is_row) child_y + child_h else child_x + child_w;
        _ = child_end;
        auto_height = @max(auto_height, main_cursor - (computed.y + layout.padding.top));
    }

    // ── Size auto-height from content ───────────────────────────
    if (content_h == null and layout.position != .absolute) {
        computed.height = auto_height + layout.padding.vertical();
    }

    // ── Lay out absolute children ───────────────────────────────
    {
        var child_opt = tree.firstChild(node_id);
        while (child_opt) |cid| {
            const cl = tree.nodeLayout(cid);
            if (cl.position == .absolute) {
                computeLayout(Tree, tree, cid, computed.x, computed.y, computed.width, computed.height);
            }
            child_opt = tree.nextSibling(cid);
        }
    }
}

fn clampOpt(val: ?f32, min_v: ?f32, max_v: ?f32) ?f32 {
    const v = val orelse return null;
    var result = v;
    if (min_v) |mn| result = @max(result, mn);
    if (max_v) |mx| result = @min(result, mx);
    return result;
}
