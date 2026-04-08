///! Behavior Tree runtime.
///!
///! A data-oriented behavior tree with arena-allocated flat node storage.
///! Trees are built once (from code, JSON, or editor) and ticked each frame.
///!
///! Supported composite/decorator/leaf types:
///!   Composite : Sequence, Selector, Parallel
///!   Decorator : Inverter, Repeater, Succeeder, RepeatUntilFail, CooldownDec
///!   Leaf      : Action, Condition, Wait
const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════
// Status
// ═══════════════════════════════════════════════════════════════════════════

pub const Status = enum(u8) {
    success,
    failure,
    running,
};

// ═══════════════════════════════════════════════════════════════════════════
// Blackboard — per-entity typed key-value store
// ═══════════════════════════════════════════════════════════════════════════

pub const BlackboardValue = union(enum) {
    int: i64,
    float: f64,
    bool_val: bool,
    string: []const u8,
};

pub const Blackboard = struct {
    entries: std.StringHashMapUnmanaged(BlackboardValue) = .empty,

    pub fn deinit(self: *Blackboard, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn setInt(self: *Blackboard, allocator: std.mem.Allocator, key: []const u8, value: i64) void {
        self.entries.put(allocator, key, .{ .int = value }) catch {};
    }

    pub fn setFloat(self: *Blackboard, allocator: std.mem.Allocator, key: []const u8, value: f64) void {
        self.entries.put(allocator, key, .{ .float = value }) catch {};
    }

    pub fn setBool(self: *Blackboard, allocator: std.mem.Allocator, key: []const u8, value: bool) void {
        self.entries.put(allocator, key, .{ .bool_val = value }) catch {};
    }

    pub fn setString(self: *Blackboard, allocator: std.mem.Allocator, key: []const u8, value: []const u8) void {
        self.entries.put(allocator, key, .{ .string = value }) catch {};
    }

    pub fn getInt(self: *const Blackboard, key: []const u8) ?i64 {
        const v = self.entries.get(key) orelse return null;
        return switch (v) {
            .int => |i| i,
            else => null,
        };
    }

    pub fn getFloat(self: *const Blackboard, key: []const u8) ?f64 {
        const v = self.entries.get(key) orelse return null;
        return switch (v) {
            .float => |f| f,
            else => null,
        };
    }

    pub fn getBool(self: *const Blackboard, key: []const u8) ?bool {
        const v = self.entries.get(key) orelse return null;
        return switch (v) {
            .bool_val => |b| b,
            else => null,
        };
    }

    pub fn getString(self: *const Blackboard, key: []const u8) ?[]const u8 {
        const v = self.entries.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn remove(self: *Blackboard, key: []const u8) void {
        _ = self.entries.remove(key);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Node types
// ═══════════════════════════════════════════════════════════════════════════

/// User-supplied tick callback.  Return `.running` to keep the node alive.
pub const TickFn = *const fn (ctx: *TickContext) Status;

/// User-supplied condition callback.
pub const ConditionFn = *const fn (ctx: *const TickContext) bool;

pub const NodeKind = enum(u8) {
    // Composites
    sequence,
    selector,
    parallel,
    // Decorators
    inverter,
    repeater,
    succeeder,
    repeat_until_fail,
    cooldown,
    // Leaves
    action,
    condition,
    wait,
};

pub const NodeData = union(enum) {
    /// Composite: stores child range [first_child .. first_child+child_count).
    composite: struct {
        first_child: u16,
        child_count: u16,
    },
    /// Decorator: single child.
    decorator: struct {
        child: u16,
        /// For repeater: max_repeats (0 = infinite).
        param_int: u32 = 0,
        /// For cooldown: seconds.
        param_float: f32 = 0,
    },
    /// Action leaf: user callback.
    action: struct {
        tick: TickFn,
    },
    /// Condition leaf: user callback.
    condition: struct {
        eval: ConditionFn,
    },
    /// Wait leaf: duration in seconds.
    wait: struct {
        duration: f32,
    },
};

pub const BtNode = struct {
    kind: NodeKind,
    data: NodeData,

    // ── Per-tick mutable state ──
    status: Status = .failure,
    /// Composite: index of the child currently running.
    running_child: u16 = 0,
    /// Wait / cooldown elapsed time.
    elapsed: f32 = 0,
    /// Repeater iteration counter.
    repeat_count: u32 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════
// TickContext — passed to user callbacks
// ═══════════════════════════════════════════════════════════════════════════

pub const TickContext = struct {
    blackboard: *Blackboard,
    allocator: std.mem.Allocator,
    delta_seconds: f32,
    entity_id: u64,
    /// Opaque user-data (world pointer, etc.)
    user_data: ?*anyopaque = null,
};

// ═══════════════════════════════════════════════════════════════════════════
// BehaviorTree — flat-array tree with tick()
// ═══════════════════════════════════════════════════════════════════════════

pub const BehaviorTree = struct {
    nodes: []BtNode,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BehaviorTree) void {
        self.allocator.free(self.nodes);
    }

    /// Reset all runtime state (status, running_child, elapsed, repeat_count).
    pub fn reset(self: *BehaviorTree) void {
        for (self.nodes) |*n| {
            n.status = .failure;
            n.running_child = 0;
            n.elapsed = 0;
            n.repeat_count = 0;
        }
    }

    /// Tick the tree starting from node 0 (root).
    pub fn tick(self: *BehaviorTree, ctx: *TickContext) Status {
        if (self.nodes.len == 0) return .failure;
        return self.tickNode(0, ctx);
    }

    fn tickNode(self: *BehaviorTree, idx: u16, ctx: *TickContext) Status {
        const node = &self.nodes[idx];
        const status = switch (node.kind) {
            .sequence => self.tickSequence(node, ctx),
            .selector => self.tickSelector(node, ctx),
            .parallel => self.tickParallel(node, ctx),
            .inverter => self.tickInverter(node, ctx),
            .repeater => self.tickRepeater(node, ctx),
            .succeeder => self.tickSucceeder(node, ctx),
            .repeat_until_fail => self.tickRepeatUntilFail(node, ctx),
            .cooldown => self.tickCooldown(node, ctx),
            .action => self.tickAction(node, ctx),
            .condition => self.tickCondition(node, ctx),
            .wait => self.tickWait(node, ctx),
        };
        node.status = status;
        return status;
    }

    // ── Composites ──────────────────────────────────────────────

    fn tickSequence(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const comp = node.data.composite;
        var i = node.running_child;
        while (i < comp.child_count) : (i += 1) {
            const child_idx = comp.first_child + i;
            const s = self.tickNode(child_idx, ctx);
            switch (s) {
                .running => {
                    node.running_child = i;
                    return .running;
                },
                .failure => {
                    node.running_child = 0;
                    return .failure;
                },
                .success => {},
            }
        }
        node.running_child = 0;
        return .success;
    }

    fn tickSelector(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const comp = node.data.composite;
        var i = node.running_child;
        while (i < comp.child_count) : (i += 1) {
            const child_idx = comp.first_child + i;
            const s = self.tickNode(child_idx, ctx);
            switch (s) {
                .running => {
                    node.running_child = i;
                    return .running;
                },
                .success => {
                    node.running_child = 0;
                    return .success;
                },
                .failure => {},
            }
        }
        node.running_child = 0;
        return .failure;
    }

    fn tickParallel(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const comp = node.data.composite;
        var success_count: u16 = 0;
        var fail_count: u16 = 0;
        var i: u16 = 0;
        while (i < comp.child_count) : (i += 1) {
            const child_idx = comp.first_child + i;
            const s = self.tickNode(child_idx, ctx);
            switch (s) {
                .success => success_count += 1,
                .failure => fail_count += 1,
                .running => {},
            }
        }
        if (fail_count > 0) return .failure;
        if (success_count == comp.child_count) return .success;
        return .running;
    }

    // ── Decorators ──────────────────────────────────────────────

    fn tickInverter(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const child_idx = node.data.decorator.child;
        return switch (self.tickNode(child_idx, ctx)) {
            .success => .failure,
            .failure => .success,
            .running => .running,
        };
    }

    fn tickRepeater(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const dec = node.data.decorator;
        const child_idx = dec.child;
        const s = self.tickNode(child_idx, ctx);
        if (s == .running) return .running;

        node.repeat_count += 1;
        if (dec.param_int > 0 and node.repeat_count >= dec.param_int) {
            node.repeat_count = 0;
            return s;
        }
        return .running; // keep repeating
    }

    fn tickSucceeder(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const child_idx = node.data.decorator.child;
        const s = self.tickNode(child_idx, ctx);
        return if (s == .running) .running else .success;
    }

    fn tickRepeatUntilFail(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const child_idx = node.data.decorator.child;
        const s = self.tickNode(child_idx, ctx);
        return switch (s) {
            .failure => .success,
            .running => .running,
            .success => .running,
        };
    }

    fn tickCooldown(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        const dec = node.data.decorator;
        if (node.elapsed > 0) {
            node.elapsed -= ctx.delta_seconds;
            if (node.elapsed > 0) return .failure;
            node.elapsed = 0;
        }
        const s = self.tickNode(dec.child, ctx);
        if (s != .running) {
            node.elapsed = dec.param_float;
        }
        return s;
    }

    // ── Leaves ──────────────────────────────────────────────────

    fn tickAction(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        _ = self;
        return node.data.action.tick(ctx);
    }

    fn tickCondition(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        _ = self;
        return if (node.data.condition.eval(ctx)) .success else .failure;
    }

    fn tickWait(self: *BehaviorTree, node: *BtNode, ctx: *TickContext) Status {
        _ = self;
        node.elapsed += ctx.delta_seconds;
        if (node.elapsed >= node.data.wait.duration) {
            node.elapsed = 0;
            return .success;
        }
        return .running;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Builder — ergonomic API for constructing trees in code
// ═══════════════════════════════════════════════════════════════════════════

pub const Builder = struct {
    nodes: std.ArrayList(BtNode),
    /// Stack of composite/decorator parent indices awaiting end().
    parent_stack: std.ArrayList(u16),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .nodes = std.ArrayList(BtNode).init(allocator),
            .parent_stack = std.ArrayList(u16).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.nodes.deinit();
        self.parent_stack.deinit();
    }

    /// Finish building and return the tree (caller owns the slice).
    pub fn build(self: *Builder) !BehaviorTree {
        const allocator = self.nodes.allocator;
        const owned = try allocator.dupe(BtNode, self.nodes.items);
        return .{
            .nodes = owned,
            .allocator = allocator,
        };
    }

    // ── Composites ──

    pub fn sequence(self: *Builder) !*Builder {
        return self.pushComposite(.sequence);
    }

    pub fn selector(self: *Builder) !*Builder {
        return self.pushComposite(.selector);
    }

    pub fn parallel(self: *Builder) !*Builder {
        return self.pushComposite(.parallel);
    }

    /// Close the current composite/decorator scope.
    pub fn end(self: *Builder) !*Builder {
        if (self.parent_stack.items.len == 0) return self;
        const parent_idx = self.parent_stack.pop();
        const parent = &self.nodes.items[parent_idx];
        switch (parent.data) {
            .composite => |*c| {
                c.child_count = @intCast(self.nodes.items.len - c.first_child);
            },
            .decorator => {},
            else => {},
        }
        return self;
    }

    // ── Decorators ──

    pub fn inverter(self: *Builder) !*Builder {
        return self.pushDecorator(.inverter, 0, 0);
    }

    pub fn repeater(self: *Builder, max_repeats: u32) !*Builder {
        return self.pushDecorator(.repeater, max_repeats, 0);
    }

    pub fn succeeder(self: *Builder) !*Builder {
        return self.pushDecorator(.succeeder, 0, 0);
    }

    pub fn repeatUntilFail(self: *Builder) !*Builder {
        return self.pushDecorator(.repeat_until_fail, 0, 0);
    }

    pub fn cooldown(self: *Builder, seconds: f32) !*Builder {
        return self.pushDecorator(.cooldown, 0, seconds);
    }

    // ── Leaves ──

    pub fn action(self: *Builder, tick_fn: TickFn) !*Builder {
        try self.nodes.append(.{
            .kind = .action,
            .data = .{ .action = .{ .tick = tick_fn } },
        });
        // If parent is a decorator, close it automatically.
        self.autoCloseDecorator();
        return self;
    }

    pub fn condition(self: *Builder, eval_fn: ConditionFn) !*Builder {
        try self.nodes.append(.{
            .kind = .condition,
            .data = .{ .condition = .{ .eval = eval_fn } },
        });
        self.autoCloseDecorator();
        return self;
    }

    pub fn wait(self: *Builder, duration_seconds: f32) !*Builder {
        try self.nodes.append(.{
            .kind = .wait,
            .data = .{ .wait = .{ .duration = duration_seconds } },
        });
        self.autoCloseDecorator();
        return self;
    }

    // ── Internals ──

    fn pushComposite(self: *Builder, kind: NodeKind) !*Builder {
        const idx: u16 = @intCast(self.nodes.items.len);
        try self.nodes.append(.{
            .kind = kind,
            .data = .{ .composite = .{
                .first_child = @intCast(self.nodes.items.len + 1),
                .child_count = 0,
            } },
        });
        try self.parent_stack.append(idx);
        return self;
    }

    fn pushDecorator(self: *Builder, kind: NodeKind, param_int: u32, param_float: f32) !*Builder {
        const idx: u16 = @intCast(self.nodes.items.len);
        try self.nodes.append(.{
            .kind = kind,
            .data = .{ .decorator = .{
                .child = @intCast(self.nodes.items.len + 1),
                .param_int = param_int,
                .param_float = param_float,
            } },
        });
        try self.parent_stack.append(idx);
        return self;
    }

    fn autoCloseDecorator(self: *Builder) void {
        if (self.parent_stack.items.len == 0) return;
        const top_idx = self.parent_stack.items[self.parent_stack.items.len - 1];
        const top = &self.nodes.items[top_idx];
        switch (top.data) {
            .decorator => {
                // Decorator has exactly one child — auto-close.
                _ = self.parent_stack.pop();
            },
            else => {},
        }
    }
};
